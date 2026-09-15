import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NavigationService {
  static final NavigationService _instance = NavigationService._internal();

  factory NavigationService() {
    return _instance;
  }

  NavigationService._internal();

  /// Tab indexes into MainLayout's `_tabWidgets` list. Only the two that the
  /// landing rule below needs are named here; the rest are mapped by
  /// [indexToRoute].
  static const int homeTab = 0;
  static const int posTab = 1;
  static const int storesTab = 7;

  /// The tab a role opens on at login, keyed by the stable role slug (§8.2 —
  /// the same slugs `roleRank` switches on in `shared/utils/role_display.dart`).
  ///
  /// Cashier opens on the till: selling *is* their shift, so any other landing
  /// costs them a tap every time they open the app. CEO, Manager and Stock
  /// keeper open on Home — their work starts from the day's numbers and the
  /// stock / report surfaces that hang off the dashboard.
  ///
  /// Driver is mapped for completeness only: a driver is routed to
  /// `DriverTerminalScreen` *instead of* MainLayout (#142), so they normally
  /// never reach a tab index at all. Should one ever land here — e.g. a driver
  /// who also holds `sales.make`, which `driverTerminalActiveProvider` reads as
  /// "not a driver terminal" — the till is still the right tab for them.
  ///
  /// An unknown / unresolved slug lands on Home, which is the only tab that is
  /// never hidden from the nav bar, so it is always a legal place to be.
  static int landingTabForRole(String? slug) =>
      (slug == 'cashier' || slug == 'driver') ? posTab : homeTab;

  /// Starts on [homeTab] rather than the role's real landing tab: at the moment
  /// a session begins the role row has not resolved from local SQLite yet, and
  /// Home is the one tab no role can have hidden. [applyRoleLanding] moves the
  /// session to the role's tab a frame or two later, once the role is known.
  final ValueNotifier<int> currentIndex = ValueNotifier<int>(homeTab);
  final List<int> _history = [];

  /// The tab this session opened on — and the tab a root-level back press falls
  /// home to. Tracks [applyRoleLanding] so "back" means "return to where this
  /// role starts", not "return to POS": a Stock keeper has no POS tab to return
  /// to (it is `sales.make`-gated and hidden from their nav bar).
  int _landingIndex = homeTab;
  int get landingIndex => _landingIndex;

  /// Whether the role-resolved landing has already been applied this session.
  /// Makes [applyRoleLanding] a one-shot: MainLayout re-schedules it on every
  /// build until it fires, and must not yank a user back to their landing tab
  /// after they have walked off it.
  bool _landingApplied = false;

  // Each tab has its own NavigatorState key
  List<GlobalKey<NavigatorState>> tabNavigatorKeys = [];

  // Per-tab nested-Navigator pop state, kept in sync by NavigatorObservers
  // attached in MainLayout. `currentTabCanPop` surfaces only the active tab's
  // value so the bottom nav can listen to a single notifier.
  final List<bool> _tabCanPop = List.filled(10, false);
  final ValueNotifier<bool> currentTabCanPop = ValueNotifier<bool>(false);

  void setTabCanPop(int tabIndex, bool canPop) {
    if (tabIndex < 0 || tabIndex >= _tabCanPop.length) return;
    _tabCanPop[tabIndex] = canPop;
    if (tabIndex == currentIndex.value) {
      currentTabCanPop.value = canPop;
    }
  }

  // Used by MainLayout to access and potentially close the drawer
  final GlobalKey<ScaffoldState> mainScaffoldKey = GlobalKey<ScaffoldState>();

  final ValueNotifier<bool> drawerOpenNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isDesktopNotifier = ValueNotifier<bool>(false);

  /// How many [AppDrawer]s are mounted right now.
  ///
  /// The drawer does **not** belong to MainLayout's Scaffold — every screen
  /// builds its own via [SharedScaffold], and a handful build one directly. So
  /// MainLayout's `onDrawerChanged` never fires and `mainScaffoldKey`'s state
  /// reports a drawer it does not own as permanently closed. Counting the
  /// drawer widget itself is the one signal that is true wherever the drawer
  /// was declared: Flutter's `DrawerController` does not build its child while
  /// dismissed, so an [AppDrawer] exists exactly while a drawer is open or
  /// animating.
  int _drawersMounted = 0;

  /// Called by [AppDrawer] as it mounts. Paired with [drawerDismounted].
  void drawerMounted() {
    _drawersMounted++;
    if (_drawersMounted == 1) drawerOpenNotifier.value = true;
  }

  /// Called by [AppDrawer] as it unmounts. Paired with [drawerMounted].
  void drawerDismounted() {
    if (_drawersMounted > 0) _drawersMounted--;
    if (_drawersMounted == 0) drawerOpenNotifier.value = false;
  }

  /// How many app-owned surfaces are currently covering the screen without
  /// being routes.
  ///
  /// [currentTabCanPop] answers this for pushed pages. It cannot answer it for
  /// a surface built as an `OverlayEntry` — Inventory's speed dial being the
  /// one that matters — and those sit in the *tab's* Overlay, inside
  /// MainLayout's body, which is below the first-run rail in the same Stack.
  /// The rail's non-blocking pointer reads this to stand aside: once the owner
  /// has opened the menu the pointer asked them to open, its caption is stale
  /// and the menu carries better labels of its own.
  int _coversMounted = 0;

  /// True while any [ScreenCover] is mounted. See [_coversMounted].
  final ValueNotifier<bool> coverOpenNotifier = ValueNotifier<bool>(false);

  /// Called by [ScreenCover] as it mounts. Paired with [coverDismounted].
  void coverMounted() {
    _coversMounted++;
    if (_coversMounted == 1) coverOpenNotifier.value = true;
  }

  /// Called by [ScreenCover] as it unmounts. Paired with [coverMounted].
  void coverDismounted() {
    if (_coversMounted > 0) _coversMounted--;
    if (_coversMounted == 0) coverOpenNotifier.value = false;
  }

  /// "Is the nav drawer covering content right now?" — the *visibility*
  /// question, which is what the first-run rail asks before cutting a hole over
  /// a button the drawer may be sitting on. Desktop counts: there the drawer is
  /// a permanent sidebar, so it is always on screen.
  bool get isDrawerOpen =>
      isDesktopNotifier.value ||
      drawerOpenNotifier.value ||
      (mainScaffoldKey.currentState?.isDrawerOpen ?? false);

  /// "Is there a *dismissable* drawer open?" — the back-button question, which
  /// is not the same as [isDrawerOpen]. Desktop's sidebar is permanent: there is
  /// nothing to dismiss, so answering the visibility question on desktop
  /// swallowed every back press into a no-op close and stranded the user (no
  /// nested pop, no tab fallback, no double-back exit).
  bool get isModalDrawerOpen =>
      !isDesktopNotifier.value &&
      (drawerOpenNotifier.value ||
          (mainScaffoldKey.currentState?.isDrawerOpen ?? false));

  /// Close callbacks published by the [AppDrawer]s currently mounted, innermost
  /// last. The drawer belongs to each screen's own Scaffold, never to
  /// `mainScaffoldKey`'s — see [_drawersMounted] — so closing it means asking
  /// the Scaffold that actually owns it.
  final List<VoidCallback> _modalDrawerClosers = <VoidCallback>[];

  /// Called by [DrawerPresence] as a dismissable drawer mounts.
  void registerModalDrawerCloser(VoidCallback closer) {
    _modalDrawerClosers.add(closer);
  }

  /// Called by [DrawerPresence] as that drawer unmounts.
  void unregisterModalDrawerCloser(VoidCallback closer) {
    _modalDrawerClosers.remove(closer);
  }

  /// Openers published by the Scaffolds that *declare* a drawer, in mount order.
  ///
  /// Deliberately a separate registry from [_modalDrawerClosers], because the
  /// closing seam cannot answer the opening question: [DrawerPresence] lives
  /// inside [AppDrawer], and Flutter does not build a drawer's child while it is
  /// shut — at the moment you want to *open* one, there is nothing mounted to
  /// ask. [DrawerHost] is mounted by the screen's own Scaffold whether the
  /// drawer is open or shut, so it can.
  ///
  /// Every tab the user has visited stays mounted (MainLayout keeps them
  /// `Offstage` rather than disposing them), so several hosts are alive at once
  /// and "the most recently registered" is *not* the one on screen. Each opener
  /// therefore vets itself and returns false when it is not the visible one;
  /// [openDrawer] walks them newest-first and takes the first that says yes.
  final List<bool Function()> _drawerOpeners = <bool Function()>[];

  /// Called by [DrawerHost] as a drawer-declaring Scaffold mounts.
  void registerDrawerOpener(bool Function() opener) {
    _drawerOpeners.add(opener);
  }

  /// Called by [DrawerHost] as that Scaffold unmounts.
  void unregisterDrawerOpener(bool Function() opener) {
    _drawerOpeners.remove(opener);
  }

  /// True when [navigator] is the tab navigator the user is actually looking at.
  /// Used by [DrawerHost] to rule itself out when it belongs to an offstage tab.
  /// With no tab shell in play (auth flow, widget tests) there is nothing to be
  /// offstage behind, so any navigator qualifies.
  bool isActiveTabNavigator(NavigatorState? navigator) {
    if (navigator == null) return false;
    if (tabNavigatorKeys.isEmpty) return true;
    final index = currentIndex.value;
    if (index >= tabNavigatorKeys.length) return false;
    return identical(tabNavigatorKeys[index].currentState, navigator);
  }

  // Neither of these writes [drawerOpenNotifier]: the mount refcount above owns
  // it, and a second writer can only desync it — `mainScaffoldKey`'s Scaffold
  // has no drawer, so a call routed there is a no-op and would leave the
  // notifier asserting a state that never happened.

  /// Open the nav drawer of the screen currently on show. Asks the [DrawerHost]s
  /// published by drawer-declaring Scaffolds; `mainScaffoldKey` is only a
  /// fallback for a drawer that really does belong to MainLayout's Scaffold.
  ///
  /// Nothing in the app calls this yet — every open today goes through the
  /// affordance itself (`Scaffold.of(ctx).openDrawer()` in [MenuButton] and the
  /// per-screen menu buttons). It exists so code with a [NavigationService] but
  /// no Scaffold context can open the drawer, and it is covered by
  /// `test/tour/drawer_host_open_test.dart` precisely because no caller would
  /// notice if it silently stopped working — which is exactly how it was broken
  /// for as long as it pointed at the drawerless `mainScaffoldKey`.
  void openDrawer() {
    for (var i = _drawerOpeners.length - 1; i >= 0; i--) {
      if (_drawerOpeners[i]()) return;
    }
    mainScaffoldKey.currentState?.openDrawer();
  }

  /// Dismiss the open nav drawer. Prefers the owning Scaffold published by
  /// [DrawerPresence]; `mainScaffoldKey` is only a fallback for a drawer that
  /// really does belong to MainLayout's Scaffold.
  void closeDrawer() {
    if (_modalDrawerClosers.isNotEmpty) {
      _modalDrawerClosers.last();
      return;
    }
    mainScaffoldKey.currentState?.closeDrawer();
  }

  final ValueNotifier<bool> storeLocked = ValueNotifier<bool>(false);

  /// The one app-wide active store (§12.1). Set by the nav-drawer store picker
  /// (and store-details deep-links); read by POS, the permission resolver, and
  /// every view screen's store filter. `null` = "All Stores" for an all-stores
  /// viewer; confined users are always pinned to a concrete store by MainLayout.
  final ValueNotifier<String?> lockedStoreId = ValueNotifier<String?>(null);

  /// §12.1: true once the user has *explicitly* picked a concrete active store
  /// this session (via the store picker / a store-details deep-link), as opposed
  /// to the silent concrete default MainLayout pins confined users to. The POS
  /// "pick a store" gate uses this so every user with more than one store must
  /// choose before selling, instead of selling from an auto-defaulted store.
  /// Reset to false on logout and whenever the active store becomes "All Stores".
  final ValueNotifier<bool> storeExplicitlyChosen = ValueNotifier<bool>(false);

  /// §12.1: true only when an all-stores viewer (CEO / all-stores Manager) has
  /// *deliberately* picked "All Stores" (the picker's All Stores option). The app
  /// never auto-lands on All Stores: MainLayout silently defaults every fresh
  /// session to a concrete active store (the user's first selectable store, or
  /// their lone store). This flag is what lets a viewer who *chose* All Stores
  /// stay there without MainLayout yanking them back to a concrete store on the
  /// next rebuild. Reset to false on logout/lock and on any concrete store pick.
  final ValueNotifier<bool> allStoresChosen = ValueNotifier<bool>(false);

  static final Map<int, String> indexToRoute = {
    0: 'dashboard',
    1: 'pos',
    2: 'inventory',
    3: 'orders',
    4: 'customers',
    5: 'payments',
    6: 'expenses',
    7: 'stores',
    8: 'cart',
    9: 'activity',
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

  /// Opens a fresh session on the neutral landing tab with the role-based
  /// landing not yet applied. Called by `AuthService.setCurrentUser`, which runs
  /// *before* the role row has resolved locally — the real landing arrives via
  /// [applyRoleLanding] once MainLayout sees the role.
  void beginSessionLanding() {
    _landingApplied = false;
    _landingIndex = homeTab;
    _history.clear();
    currentIndex.value = homeTab;
    currentTabCanPop.value = false;
  }

  /// Applies the role's landing tab — **once** per session.
  ///
  /// MainLayout calls this on every build once permissions resolve; every call
  /// after the first is a no-op, so a user who has since moved to another tab is
  /// never yanked back. The move itself is also skipped when the session is no
  /// longer sitting on the untouched neutral default, so someone who picked a
  /// tab inside the resolve window keeps their pick.
  void applyRoleLanding(int index) {
    if (_landingApplied) return;
    _landingApplied = true;
    _landingIndex = index;
    if (currentIndex.value == homeTab) setIndex(index);
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
  ///   onPopInvokedWithResult: (didPop, _) { if (!didPop) handleBackPress(ctx); }
  /// Make sure PopScope has canPop: false so Flutter never pops on its own.
  void handleBackPress(BuildContext context) {
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

    // Step 1: close the drawer if one is open *and dismissable*. Desktop's
    // sidebar is permanent, so it must not consume the press — see
    // [isModalDrawerOpen].
    if (isModalDrawerOpen) {
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

    // Step 3: At the root of a tab. If not the landing tab, fall home to it.
    // Landing-relative, not POS-relative: a Stock keeper's POS tab is hidden
    // from their nav bar, so bouncing them there would strand them on a screen
    // MainLayout has to bounce back out of.
    if (currentIndex.value != _landingIndex) {
      debugPrint(
        '[NavigationService] At root of a non-landing tab. '
        'Switching to landing tab $_landingIndex.',
      );
      setIndex(_landingIndex);
      return;
    }

    // Step 4: At the root of the landing tab — double-back-to-exit
    debugPrint(
      '[NavigationService] At root of the landing tab. '
      'Checking double-back exit...',
    );
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      debugPrint('[NavigationService] Showing exit warning snackbar');
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('press back again to close the app'),
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

  /// Called right after login. With staff management removed, the lone
  /// owner has no store lock — they can move freely across all
  /// stores they own. Kept as a no-op for callers that still invoke
  /// it during login flow.
  void applyUserStoreLock(String? storeId) {
    storeLocked.value = false;
    lockedStoreId.value = null;
    storeExplicitlyChosen.value = false;
    allStoresChosen.value = false;
  }

  /// Called on logout — removes all store restrictions.
  void clearStoreLock() {
    storeLocked.value = false;
    lockedStoreId.value = null;
    storeExplicitlyChosen.value = false;
    allStoresChosen.value = false;
  }

  /// Resets navigation state to defaults. Call on logout/lock so the next
  /// session starts clean (neutral landing tab, empty history, role landing
  /// un-applied).
  void resetNavigation() {
    _history.clear();
    _landingApplied = false;
    _landingIndex = homeTab;
    currentIndex.value = homeTab;
    _lastBackPress = null;
    _lastHandleTime = null;
    for (int i = 0; i < _tabCanPop.length; i++) {
      _tabCanPop[i] = false;
    }
    currentTabCanPop.value = false;
    _drawersMounted = 0;
    drawerOpenNotifier.value = false;
    _modalDrawerClosers.clear();
    _drawerOpeners.clear();
    _coversMounted = 0;
    coverOpenNotifier.value = false;
  }

  /// Manually update the active store (§12.1). [explicit] marks a deliberate
  /// user pick — only an explicit pick of a *concrete* store counts as "chosen"
  /// (picking "All Stores", `id == null`, never does), so the POS gate keeps
  /// prompting multi-store users until they choose. MainLayout's silent
  /// confined-user default passes `explicit: false`.
  void setLockedStore(String? id, {bool explicit = true}) {
    lockedStoreId.value = id;
    storeExplicitlyChosen.value = explicit && id != null;
    // Only a deliberate "All Stores" pick (explicit, id == null) latches the
    // all-stores choice; any concrete store (or the silent default) clears it so
    // MainLayout never treats a fresh/auto null as "the user wants All Stores".
    allStoresChosen.value = explicit && id == null;
  }
}
