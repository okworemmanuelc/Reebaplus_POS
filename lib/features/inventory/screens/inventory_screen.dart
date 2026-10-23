import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart'; // RESPONSIVE: utility imported
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/coach_hint_banner.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/core/crates/empty_crates_roster.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_history_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_manufacturers_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manage_categories_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_details_route.dart';
import 'package:reebaplus_pos/core/constants/category_filter.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/core/widgets/app_speed_dial_fab.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// Key prefix marking one complete product row in the Products tab. The
/// viewport regression suite (PRD #239) asserts that at least one row carrying
/// this prefix is laid out and hit-testable at every supported viewport. Keys
/// are per-product because sibling rows in a sliver list may not share one.
const String kInventoryProductRowKeyPrefix = 'inventory-product-row-';

/// The row key for [productId].
ValueKey<String> inventoryProductRowKey(String productId) =>
    ValueKey<String>('$kInventoryProductRowKeyPrefix$productId');

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});
  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen>
        // TickerProviderStateMixin (plural): the tab set is dynamic (role /
        // business-type guards), so the TabController is rebuilt when the visible
        // count changes. SingleTickerProviderStateMixin permanently records its one
        // ticker and would throw on the second controller — the plural mixin tracks
        // tickers in a set and releases each on dispose.
        with
        TickerProviderStateMixin {
  late TabController _tabController;
  int _currentTab = 0;
  String _selectedManufacturer = 'all';
  // Mirrors the §12.1 nav-drawer store picker ('all' = "All Stores"). Synced
  // from `lockedStoreProvider` in `_buildSupplierFilter`; no per-screen dropdown.
  String _selectedStoreId = 'all';
  // 'all' | 'low' | 'out' | 'expiry' | 'archived'
  String _stockFilter = 'all';
  List<ProductDataWithStock> _dbProducts = [];

  /// The products the normal list and the figure cards count: archived ones
  /// (`isAvailable == false`, #487) left out. The other tabs keep every product.
  List<ProductDataWithStock> get _activeProducts =>
      _dbProducts.where((p) => p.product.isAvailable).toList();

  /// Archived products (#487), shown only under the Archived filter.
  List<ProductDataWithStock> get _archivedProducts =>
      _dbProducts.where((p) => !p.product.isAvailable).toList();

  /// [_stockFilter], falling back to 'all' once nothing is archived (a synced
  /// unarchive can empty the Archived filter while it is selected; its card
  /// then disappears, so the list must not stay stuck on it).
  String get _effectiveStockFilter =>
      _stockFilter == 'archived' && _archivedProducts.isEmpty
      ? 'all'
      : _stockFilter;
  List<ManufacturerData> _dbManufacturers = [];
  List<CategoryData> _dbCategories = [];
  String? _selectedCategoryId;
  // Products-tab header search (§16.4, amended — reuses the POS toggle pattern).
  bool _showSearch = false;
  // Discoverability banner (issue #110): "press and hold to edit". Seeded from
  // the UI-hint service in initState (per staff member, local-only); the render
  // also checks Gates.editProductPrice so it only reaches users who can actually
  // long-press-edit. Dismissing it retires the banner permanently for that user.
  bool _showLongPressHint = false;
  // The banner's dismissal is "per staff member" (issue #110 AC), so scope the
  // shared UI-hint key to the current device user. Falls back to the bare key
  // when no user is resolved (not expected on this authenticated screen).
  String get _longPressHintKey {
    final userId = ref.read(deviceUserIdProvider).value;
    return userId == null || userId.isEmpty
        ? UiHintService.hintInventoryLongpress
        : '${UiHintService.hintInventoryLongpress}_$userId';
  }

  String _searchQuery = '';
  final _searchCtrl = TextEditingController();
  int _totalCrateAssetsSum = 0;

  bool _isFirstLoad = true;
  StreamSubscription<List<ProductDataWithStock>>? _productsSub;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  StreamSubscription<List<CategoryData>>? _categoriesSub;
  StreamSubscription<int>? _emptyCratesSumSub;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  void _onTabChanged() {
    if (mounted && _tabController.index != _currentTab) {
      setState(() => _currentTab = _tabController.index);
    }
  }

  /// The tab keys visible for the current role / permissions / business type
  /// (master plan §16.3 / §16.7 / §16.10):
  ///  - products  — always.
  ///  - suppliers — `suppliers.manage` (CEO; Manager if toggled on).
  ///  - crates    — Bar / Beer distributor businesses only.
  ///  - manufacturers — beside crates (#389): every brand, bottle or not.
  ///  - history   — CEO / Manager / Stock keeper (own store); Cashier hidden.
  ///
  /// Returns null until the role, its grants, and the business row have all
  /// resolved locally. The caller shows a static loading state until then, so
  /// the tab bar reveals its final set in one shot rather than popping the
  /// extra tabs in a frame later (which read as a staged "entrance").
  List<String>? _computeVisibleTabs(BuildContext context) {
    final role = ref.watch(currentUserRoleProvider);
    if (role == null) return null;
    final grantsAsync = ref.watch(rolePermissionsProvider(role.id));
    final businessesAsync = ref.watch(localBusinessesProvider);
    if (!grantsAsync.hasValue || !businessesAsync.hasValue) return null;

    // Use the EFFECTIVE permission set (role grants ± this user's overrides), not
    // the raw role grants — otherwise a CEO's per-staff override of
    // `suppliers.manage` wouldn't change the visible tabs.
    final showSuppliers = Gates.manageSuppliers.allows(ref);
    final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
    final showHistory =
        role.slug == 'ceo' ||
        role.slug == 'manager' ||
        role.slug == 'stock_keeper';

    return [
      'products',
      if (showSuppliers) 'suppliers',
      if (showCrates) 'crates',
      if (showCrates) 'manufacturers',
      if (showHistory) 'history',
    ];
  }

  /// Keeps [_tabController] in sync with the visible-tab set. The labels and
  /// bodies are rebuilt from [_tabKeys] every build, so the only thing the
  /// controller actually pins is its *length* — we therefore recreate it only
  /// when the tab count changes (tabs appear/disappear as role / business-type
  /// data resolves), disposing the old one first to release its ticker.
  void _syncTabController(List<String> keys) {
    if (_listEquals(keys, _tabKeys)) return;
    final priorKey = _currentTab < _tabKeys.length
        ? _tabKeys[_currentTab]
        : 'products';
    var newIndex = keys.indexOf(priorKey);
    if (newIndex < 0) newIndex = 0;
    _tabKeys = keys;
    _currentTab = newIndex;
    if (_tabController.length != keys.length) {
      _tabController.removeListener(_onTabChanged);
      _tabController.dispose();
      _tabController = TabController(
        length: keys.length,
        vsync: this,
        initialIndex: newIndex,
      );
      _tabController.addListener(_onTabChanged);
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _tabLabel(String key) => switch (key) {
    'suppliers' => 'Suppliers',
    'crates' => 'Empty Crates',
    'manufacturers' => 'Manufacturers',
    'history' => 'History',
    _ => ref.watch(industryLexiconProvider).itemPlural,
  };

  /// One tab's body as slivers. Every tab is a scroll view of its own, so no
  /// band inside a tab may depend on a height the parent supplies — that
  /// dependency is what starved the stock list to zero (PRD #239).
  ///
  /// The storage keys keep each tab's scroll offset across tab switches.
  TabSliverView _tabSliverView(BuildContext context, String key) =>
      switch (key) {
        'suppliers' => TabSliverView(
          storageKey: 'inventory-suppliers',
          slivers: _suppliersTabSlivers(context),
        ),
        'crates' => TabSliverView(
          storageKey: 'inventory-crates',
          slivers: _cratesTabSlivers(context),
        ),
        'manufacturers' => const TabSliverView(
          storageKey: 'inventory-manufacturers',
          slivers: [InventoryManufacturersTab()],
        ),
        'history' => TabSliverView(
          storageKey: 'inventory-history',
          slivers: [
            InventoryHistoryTab(
              storeId: _selectedStoreId == 'all' ? null : _selectedStoreId,
            ),
          ],
        ),
        _ => TabSliverView(
          storageKey: 'inventory-products',
          slivers: _productsTabSlivers(context),
        ),
      };

  // Currently-visible tab keys, in order. Recomputed in build() from role /
  // permission / business-type guards (§16.7 / §16.10); the TabController is
  // rebuilt when this set changes. 'products' is always present.
  List<String> _tabKeys = const ['products'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabKeys.length, vsync: this);
    _tabController.addListener(_onTabChanged);

    // Issue #110: surface the "press and hold to edit" banner a couple of times
    // per staff member. Visibility is further gated on Gates.editProductPrice at
    // render time, so it only reaches users who can use the gesture.
    uiHintService.shouldShow(_longPressHintKey).then((show) {
      if (show && mounted) {
        setState(() => _showLongPressHint = true);
        // Count this display as a passive view so an ignored hint still retires
        // after `_retireAfter` visits (never shown forever).
        uiHintService.markShown(_longPressHintKey);
      }
    });

    // Defer all DB stream subscriptions until after the first frame so that
    // frame renders immediately without competing with 8+ SQL queries on the
    // Drift background isolate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final db = ref.read(databaseProvider);

      // §12.1: the active store now comes from the nav-drawer store picker.
      // Bootstrap the products subscription once; `_buildSupplierFilter`
      // re-subscribes whenever the picker (lockedStoreProvider) changes.
      _subscribeToProducts();

      _manufacturersSub = db.inventoryDao.watchAllManufacturers().listen((
        data,
      ) {
        if (mounted) setState(() => _dbManufacturers = data);
      }, onError: (e) => debugPrint('Error watching manufacturers: $e'));

      _categoriesSub = db.inventoryDao.watchAllCategories().listen((data) {
        if (!mounted) return;
        setState(() {
          _dbCategories = data;
          // #109: a category the user had filtered on can vanish (deleted via
          // Manage categories here, or on another device). Drop the dangling
          // selection back to "All" so the filter doesn't strand the list on a
          // category that no longer exists. The Uncategorized sentinel is not a
          // real category id, so it's preserved.
          if (_selectedCategoryId != null &&
              _selectedCategoryId != kUncategorizedCategoryId &&
              !data.any((c) => c.id == _selectedCategoryId)) {
            _selectedCategoryId = null;
          }
        });
      }, onError: (e) => debugPrint('Error watching categories: $e'));

      // Per-manufacturer full/empty crate figures are read reactively in the
      // Crates tab via fullCratesByManufacturerProvider /
      // storeCrateBalancesProvider so they re-scope to the active store
      // (§16.8.1 Phase 2) without re-plumbing imperative subscriptions.
    });
  }

  @override
  void dispose() {
    _productsSub?.cancel();
    _manufacturersSub?.cancel();
    _categoriesSub?.cancel();
    _emptyCratesSumSub?.cancel();
    _searchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _subscribeToProducts() {
    _productsSub?.cancel();
    _emptyCratesSumSub?.cancel();

    final storeId = _selectedStoreId == 'all' ? null : _selectedStoreId;

    final db = ref.read(databaseProvider);
    final productStream = storeId != null
        ? db.inventoryDao.watchProductDatasWithStockByStore(storeId)
        : db.inventoryDao.watchAllProductDatasWithStock();

    _productsSub = productStream.listen((data) {
      if (mounted) {
        setState(() {
          _dbProducts = data;
          _isFirstLoad = false;
        });
      }
    }, onError: (e) => debugPrint('Error watching inventory: $e'));

    _emptyCratesSumSub = db.inventoryDao.watchTotalCrateAssets().listen((
      count,
    ) {
      if (mounted) {
        setState(() => _totalCrateAssetsSum = count);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // Defense-in-depth (hard rules #6/#7): Inventory is gated on stock.view
    // (§16.7) — Gates.viewInventory. The drawer item and bottom-nav Stock tab
    // already hide without it; Guarded.screen covers a deep-link / programmatic
    // switch to the tab and waits for the permission set to resolve first (no
    // denial flash). Inventory is a bottom-nav tab, so the loading/denied
    // surfaces keep the SharedScaffold chrome (nav stays reachable) instead of
    // the default full-screen scaffold.
    return Guarded.screen(
      gate: Gates.viewInventory,
      loading: SharedScaffold(
        activeRoute: 'inventory',
        backgroundColor: _bg,
        body: const SizedBox.shrink(),
      ),
      denied: SharedScaffold(
        activeRoute: 'inventory',
        backgroundColor: _bg,
        appBar: InventoryTopBar(
          icon: AppIcons.inventory,
          title: 'Inventory',
          height: inventoryTopBarHeight(context),
        ),
        body: Center(
          child: Text(
            'You don\'t have access to Inventory.',
            style: context.regularStyle(14).copyWith(color: _subtext),
          ),
        ),
      ),
      builder: _buildInventory,
    );
  }

  /// The Inventory body, shown once [Gates.viewInventory] has resolved and
  /// granted. Split out of [build] so the `Guarded.screen` guard above owns
  /// the permissions-ready / denial decision.
  Widget _buildInventory(BuildContext context) {
    // Resolve the visible tabs (role / permission / business-type guards).
    // Null = the gating data hasn't loaded yet → show a static loading state
    // and don't touch the TabController, so the tab bar reveals its final set
    // in one shot instead of popping extra tabs in a frame later.
    final visibleTabs = _computeVisibleTabs(context);
    final tabsReady = visibleTabs != null;
    if (tabsReady) _syncTabController(visibleTabs);

    final onProductsTab =
        tabsReady &&
        _currentTab < _tabKeys.length &&
        _tabKeys[_currentTab] == 'products';
    // Products-tab speed dial — one "+" splits the two distinct acts (ADR 0006):
    // Add Product (create a product + record shelf stock, no supplier invoice)
    // and Receive Stock (log a supplier delivery). Each option cites its own
    // named gate (ADR 0002), never a role: Add Product is `products.add`, and
    // Receive Stock is stock-keeper-or-adder. The widget collapses to a single
    // direct FAB when only one gate passes and shows nothing when neither does,
    // so a stock keeper with only `stock.add` still gets a direct Receive Stock
    // FAB but never the Add Product option.
    final lex = ref.watch(industryLexiconProvider);
    final speedDialActions = <AppSpeedDialAction>[
      if (Gates.addProduct.allows(ref))
        AppSpeedDialAction(
          icon: AppIcons.tag,
          label: 'Add ${lex.item}',
          description:
              'Create a ${lex.item.toLowerCase()} and set what’s on your shelf',
          onPressed: () => Navigator.of(
            context,
          ).push(slideDownRoute(const AddProductScreen())),
        ),
      if (Gates.receiveStock.allows(ref))
        AppSpeedDialAction(
          icon: AppIcons.supplier,
          label: 'Receive Stock',
          description: 'Log a delivery from a supplier',
          onPressed: () => Navigator.of(
            context,
          ).push(slideDownRoute(const ReceiveStockScreen())),
        ),
    ];

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'inventory',
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(context),
        floatingActionButton: onProductsTab
            ? SpotlightTarget(
                id: SpotlightTargetId.addProductFab,
                child: AppSpeedDialFab(
                  actions: speedDialActions,
                  reserveBottomInset: false,
                ),
              )
            : null,
        body: SafeArea(
          top: false,
          child: !tabsReady
              ? const Center(child: CircularProgressIndicator())
              // One scrollable surface (PRD #239): the summary cards scroll
              // away, the tab bar pins, and each tab is its own scroll view
              // whose filter band is a sliver above its list. Nothing inside a
              // tab depends on a supplied height, so the short body a
              // NestedScrollView hands its child can no longer crush the stock
              // list to zero.
              : AppRefreshWrapper(
                  child: TabbedSliverScaffold(
                    controller: _tabController,
                    // The hairline under the tab bar is reserved on top of the
                    // 48dp floor, so every tab keeps its full target (#392).
                    tabBarExtent: kMinInteractiveDimension,
                    tabBarChromeExtent: 1,
                    headerSlivers: [
                      SliverToBoxAdapter(child: _buildSummaryCards(context)),
                    ],
                    tabBar: _buildTabBar(context),
                    tabViews: [
                      for (final key in _tabKeys) _tabSliverView(context, key),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// The menu button (48dp) under 600dp; the rail carries it at 600dp+.
  Widget? _menuLeading(BuildContext context) => context.isRailLayout
      ? null
      : const SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: MenuButton(),
        );

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return InventoryTopBar(
      icon: AppIcons.inventory,
      title: 'Inventory',
      subtitle: ref.watch(activeStoreLabelProvider),
      height: inventoryTopBarHeight(context),
      leading: _menuLeading(context),
      actions: [
        // Search toggle — only meaningful on the Products tab (§16.4).
        if (_currentTab == 0)
          InventoryBarAction(
            tooltip: _showSearch
                ? 'Close search'
                : 'Search ${ref.watch(industryLexiconProvider).itemPluralLower}',
            icon: _showSearch ? AppIcons.close : AppIcons.search,
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchCtrl.clear();
                _searchQuery = '';
              }
            }),
          ),
        // Stock Take icon (§16.1) → Daily Stock Count. §17.4 access: Stock
        // keeper, Manager, CEO — AND the `stock.adjust` permission, since the
        // count/damage actions decrement stock and the key is independently
        // revocable. Otherwise hide the icon entirely (hard rule #7).
        if (Gates.dailyStockCount.allows(ref))
          InventoryBarAction(
            tooltip: 'Daily Stock Count',
            icon: AppIcons.auditCheck,
            onPressed: () => Navigator.push(
              context,
              slideDownRoute(
                StockCountScreen(
                  storeId: ref.read(navigationProvider).lockedStoreId.value,
                ),
              ),
            ),
          ),
        const InventoryLiveBell(),
      ],
    );
  }

  Widget _buildSummaryCards(BuildContext context) {
    if (_isFirstLoad) return const SizedBox.shrink();
    // Archived products (#487) are not on sale and not counted here; they have
    // their own card.
    final products = _activeProducts;
    final archivedCount = _archivedProducts.length;
    final filter = _effectiveStockFilter;

    final totalItems = products.length;
    final lowStock = products
        .where(
          (p) =>
              p.totalStock > 0 && p.totalStock <= p.product.lowStockThreshold,
        )
        .length;
    final outOfStock = products.where((p) => p.totalStock == 0).length;
    // Near-expiry surfacing (§16.4 / §16.5): products expired or within 30 days.
    final nearExpiry = products.where((p) => _isNearExpiry(p.product)).length;

    final totalCrates = _totalCrateAssetsSum.toDouble();

    final cards = <Widget>[
      InventoryFigureCard(
        key: const ValueKey('inventory-summary-total'),
        label: 'Total SKUs',
        value: '$totalItems',
        icon: AppIcons.category,
        tone: IconTileTone.info,
        selected: filter == 'all',
        onTap: () => setState(() {
          _stockFilter = 'all';
          _tabController.animateTo(0);
        }),
      ),
      InventoryFigureCard(
        key: const ValueKey('inventory-summary-low'),
        label: 'Low Stock',
        value: '$lowStock',
        icon: AppIcons.warning,
        tone: IconTileTone.warning,
        selected: filter == 'low',
        onTap: () => setState(() {
          _stockFilter = 'low';
          _tabController.animateTo(0);
        }),
      ),
      InventoryFigureCard(
        key: const ValueKey('inventory-summary-out'),
        label: 'Out of Stock',
        value: '$outOfStock',
        icon: AppIcons.block,
        tone: IconTileTone.danger,
        selected: filter == 'out',
        onTap: () => setState(() {
          _stockFilter = 'out';
          _tabController.animateTo(0);
        }),
      ),
      // Total Crates only when the Empty Crates tab is visible (Bar / Beer
      // distributor — §16.10). Jumps to that tab by its dynamic index.
      if (_tabKeys.contains('crates'))
        InventoryFigureCard(
          key: const ValueKey('inventory-summary-crates'),
          label: 'Total Crates',
          value: '${totalCrates.toInt()}',
          icon: AppIcons.beerMug,
          tone: IconTileTone.green,
          selected: _currentTab == _tabKeys.indexOf('crates'),
          onTap: () => setState(() {
            _tabController.animateTo(_tabKeys.indexOf('crates'));
          }),
        ),
      // Near Expiry — last card; available for all business types (§16.5).
      // Tapping filters the Products list to flagged items, which already
      // sort soonest-expiry first.
      InventoryFigureCard(
        key: const ValueKey('inventory-summary-expiry'),
        label: 'Near Expiry',
        value: '$nearExpiry',
        icon: AppIcons.pending,
        tone: IconTileTone.warning,
        selected: filter == 'expiry',
        onTap: () => setState(() {
          _stockFilter = 'expiry';
          _tabController.animateTo(0);
        }),
      ),
      // Archived (#487) — only once something is archived, so a shop that
      // never archives sees no extra card. Tapping lists just the archived
      // products; each still opens Product Details.
      if (archivedCount > 0)
        InventoryFigureCard(
          key: const ValueKey('inventory-summary-archived'),
          label: 'Archived',
          value: '$archivedCount',
          icon: AppIcons.archive,
          tone: IconTileTone.neutral,
          selected: filter == 'archived',
          onTap: () => setState(() {
            _stockFilter = 'archived';
            _tabController.animateTo(0);
          }),
        ),
    ];

    // Measured, not a viewport predicate (#392): the cards share one row when
    // each gets at least [cardWidth]; otherwise they keep that width and
    // scroll sideways, as before.
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.maxWidth);
        final gap = context.getRSize(10);
        final cardWidth = context.getRSize(112);
        final inner = constraints.maxWidth - 2 * gutter;
        // Sharing the row only needs a little less than the scrolling width:
        // "Out of Stock" still fits on one line at 104dp.
        final minShared = context.getRSize(104);
        final fits =
            inner >= cards.length * minShared + (cards.length - 1) * gap;
        final padding = EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(12),
          gutter,
          context.getRSize(12),
        );
        if (fits) {
          return Padding(
            padding: padding,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    Expanded(child: cards[i]),
                  ],
                ],
              ),
            ),
          );
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  SizedBox(width: cardWidth, child: cards[i]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabBar(BuildContext context) {
    final t = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Tab labels start at the content column's edge (the TabBar's own
        // 16dp label padding is the gutter inside the cap).
        final offset = math.max(
          0.0,
          inventoryGutter(context, constraints.maxWidth) - context.getRSize(16),
        );
        return Container(
          decoration: BoxDecoration(
            color: t.colorScheme.surface,
            border: Border(bottom: BorderSide(color: t.dividerColor)),
          ),
          padding: EdgeInsets.symmetric(horizontal: offset),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            labelColor: t.colorScheme.primary,
            unselectedLabelColor: _subtext,
            labelStyle: context.boldStyle(14),
            unselectedLabelStyle: context.semiBoldStyle(14),
            indicatorColor: t.colorScheme.primary,
            indicatorWeight: 3,
            tabs: [for (final key in _tabKeys) Tab(text: _tabLabel(key))],
          ),
        );
      },
    );
  }

  List<Widget> _productsTabSlivers(BuildContext context) {
    if (_isFirstLoad) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    // Archived products (#487) show only under their own filter.
    final filter = _effectiveStockFilter;
    var list = filter == 'archived' ? _archivedProducts : _activeProducts;

    if (filter == 'low') {
      list = list
          .where(
            (p) =>
                p.totalStock > 0 && p.totalStock <= p.product.lowStockThreshold,
          )
          .toList();
    } else if (filter == 'out') {
      list = list.where((p) => p.totalStock == 0).toList();
    } else if (filter == 'expiry') {
      list = list.where((p) => _isNearExpiry(p.product)).toList();
    }

    if (_selectedManufacturer != 'all') {
      final mfrId = _dbManufacturers
          .where((m) => m.name == _selectedManufacturer)
          .map((m) => m.id)
          .firstOrNull;
      list = list.where((p) => p.product.manufacturerId == mfrId).toList();
    }
    if (_selectedCategoryId == kUncategorizedCategoryId) {
      // The Uncategorized bucket (#109): products with no category — e.g. those
      // orphaned when their category was deleted.
      list = list.where((p) => p.product.categoryId == null).toList();
    } else if (_selectedCategoryId != null) {
      list = list
          .where((p) => p.product.categoryId == _selectedCategoryId)
          .toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list
          .where(
            (p) =>
                p.product.name.toLowerCase().contains(q) ||
                (p.product.subtitle?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    // Near-expiry surfacing (§16.4, amended): bubble flagged products
    // (expired / within 30 days) to the top, soonest first; the rest keep
    // their existing order.
    list = _sortNearExpiryFirst(list);

    final categoryNames = {for (final c in _dbCategories) c.id: c.name};
    // "Bottle Crate" only in a shop that counts empty crates (#487).
    final crates = businessTracksCrates(ref.watch(currentBusinessProvider));

    return [
      if (_showSearch) SliverToBoxAdapter(child: _buildSearchField(context)),
      SliverToBoxAdapter(child: _buildSupplierFilter(context)),
      // Issue #110: press-and-hold-to-edit discoverability banner. Shown only
      // to staff the price-edit gate lets long-press-edit (matching the
      // gesture's own guard on `_buildProductRow`), only while there are
      // products to hold, and only until this staff member dismisses it
      // (which retires it permanently for them).
      if (_showLongPressHint &&
          list.isNotEmpty &&
          Gates.editProductPrice.allows(ref))
        _cappedBox(
          EdgeInsets.only(top: context.getRSize(4)),
          CoachHintBanner(
            message:
                'Press and hold a '
                '${ref.watch(industryLexiconProvider).itemLower}'
                ' to edit it.',
            onDismiss: () {
              setState(() => _showLongPressHint = false);
              uiHintService.markDismissed(_longPressHintKey);
            },
          ),
        ),
      if (list.isEmpty)
        // Genuinely empty catalogue (not a filter/search miss) hands off to the
        // persona-aware first-run empty state — the "Add your first product"
        // CTA / neutral message (Seam 2, #34). A filter miss over a populated
        // catalogue keeps the "no products matching" copy.
        //
        // `hasScrollBody: false` sizes the body to the LARGER of the remaining
        // viewport and its own natural height, so the empty state still centres
        // on a roomy phone and scrolls — rather than overflowing — once the
        // chrome above it has eaten the screen.
        SliverFillRemaining(
          hasScrollBody: false,
          child:
              ref.watch(firstRunSurfaceStateProvider) !=
                  FirstRunSurfaceState.hasContent
              ? const FirstRunEmptyState()
              : Center(
                  child: Text(
                    'No ${ref.watch(industryLexiconProvider).itemPluralLower} matching filters',
                    style: context.regularStyle(14).copyWith(color: _subtext),
                  ),
                ),
        )
      else
        _cappedSliver(
          top: context.getRSize(12),
          sliver: SliverList.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(10)),
              child: _buildProductRow(
                context,
                list[i],
                categoryNames[list[i].product.categoryId],
                crates: crates,
              ),
            ),
          ),
        ),
    ];
  }

  /// Bottom room under every tab's list: clear of the speed-dial FAB, plus the
  /// system nav inset where the screen owns it (#392: `deviceBottomPadding`,
  /// 0 above the bottom bar).
  double _listBottomPadding(BuildContext context) =>
      context.getRSize(120) + context.deviceBottomPadding;

  /// [sliver] inside the centred content column (`kInventoryMaxContentWidth`),
  /// measured from the sliver's own width.
  Widget _cappedSliver({
    required Widget sliver,
    double top = 0,
    double? bottom,
  }) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final gutter = inventoryGutter(context, constraints.crossAxisExtent);
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          top,
          gutter,
          bottom ?? _listBottomPadding(context),
        ),
        sliver: sliver,
      );
    },
  );

  /// A box child in the centred content column.
  Widget _cappedBox(EdgeInsets padding, Widget child) => SliverToBoxAdapter(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.maxWidth);
        return Padding(
          padding: padding.add(EdgeInsets.symmetric(horizontal: gutter)),
          child: child,
        );
      },
    ),
  );

  List<Widget> _suppliersTabSlivers(BuildContext context) {
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    return [
      _cappedBox(
        EdgeInsets.symmetric(vertical: context.getRSize(16)),
        AppButton(
          text: 'Add Supplier',
          variant: AppButtonVariant.secondary,
          icon: AppIcons.add,
          onPressed: () => SupplierFormSheet.show(context),
        ),
      ),
      if (suppliers.isEmpty)
        // Blank while the first download is still running: an empty list says
        // nothing about the business until it has finished (#313).
        SliverFillRemaining(
          hasScrollBody: false,
          child: ref.watch(firstDownloadInProgressProvider)
              ? const SizedBox.shrink()
              : Center(
                  child: Text(
                    'No suppliers added yet',
                    style: context.regularStyle(14).copyWith(color: _subtext),
                  ),
                ),
        )
      else
        _cappedSliver(
          sliver: SliverList.builder(
            itemCount: suppliers.length,
            itemBuilder: (_, i) {
              final s = suppliers[i];
              final contactDetails = [
                s.phone,
                s.email,
                s.address,
              ].where((x) => x != null && x.isNotEmpty).join(', ');
              return Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(12)),
                child: SettingsRow(
                  key: ValueKey('inventory-supplier-row-${s.id}'),
                  icon: AppIcons.bank,
                  tone: IconTileTone.info,
                  title: s.name,
                  subtitle: contactDetails.isEmpty ? null : contactDetails,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SupplierDetailScreen(supplierId: s.id),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }

  /// Build the per-manufacturer crate stats (keyed by manufacturer id) from the
  /// active-store full/empty maps resolved in [_cratesTabSlivers].
  List<ManufacturerCrateStats> _computeCrateStats(
    Map<String, int> fullByMfr,
    Map<String, int> emptyByMfr,
  ) {
    final allMfrs = {...fullByMfr.keys, ...emptyByMfr.keys};
    return allMfrs.map((mfr) {
      return ManufacturerCrateStats(
        manufacturer: mfr,
        totalBottles: fullByMfr[mfr] ?? 0,
        emptyCrates: emptyByMfr[mfr] ?? 0,
        totalValueKobo: 0,
      );
    }).toList()..sort((a, b) => a.manufacturer.compareTo(b.manufacturer));
  }

  Widget _buildSupplierFilter(BuildContext context) {
    // §12.1: the active store comes from the nav-drawer store picker. Mirror it
    // into the local filter ('all' = "All Stores") and re-subscribe when it
    // changes. Confinement is enforced upstream — the picker only offers the
    // user's selectable stores, and MainLayout pins confined users to a real
    // store — so there's no per-screen store dropdown here anymore.
    final desiredStoreId = ref.watch(lockedStoreProvider).value ?? 'all';
    if (_selectedStoreId != desiredStoreId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedStoreId == desiredStoreId) return;
        setState(() => _selectedStoreId = desiredStoreId);
        _subscribeToProducts();
      });
    }
    final itemStyle = context.mediumStyle(14).copyWith(color: _text);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.maxWidth);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(12),
            gutter,
            context.getRSize(4),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Category dropdown (§16.4, amended): replaces the old chip row,
              // drives `_selectedCategoryId`. The store is now picked in the
              // nav bar.
              Expanded(
                child: _isFirstLoad
                    ? const SizedBox.shrink()
                    : AppDropdown<String>(
                        value: _selectedCategoryId ?? 'all',
                        labelText: 'Category',
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All', style: itemStyle),
                          ),
                          ..._dbCategories.map(
                            (c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                c.name,
                                overflow: TextOverflow.ellipsis,
                                style: itemStyle,
                              ),
                            ),
                          ),
                          // #109: filter to products with no category.
                          DropdownMenuItem(
                            value: kUncategorizedCategoryId,
                            child: Text(
                              'Uncategorized',
                              overflow: TextOverflow.ellipsis,
                              style: itemStyle,
                            ),
                          ),
                        ],
                        onChanged: (val) => setState(
                          () => _selectedCategoryId =
                              (val == null || val == 'all') ? null : val,
                        ),
                      ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _isFirstLoad
                    ? const SizedBox.shrink()
                    : AppDropdown<String>(
                        value: _selectedManufacturer,
                        labelText: 'Manufacturer',
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('All', style: itemStyle),
                          ),
                          ..._dbManufacturers.map(
                            (m) => DropdownMenuItem(
                              value: m.name,
                              child: Text(
                                m.name,
                                overflow: TextOverflow.ellipsis,
                                style: itemStyle,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) => setState(
                          () => _selectedManufacturer = val ?? 'all',
                        ),
                      ),
              ),
              // #109: Manage categories (rename / delete → Uncategorized).
              // Gated on the same permission as adding a product —
              // product-catalogue management. Bottom-aligned with the fields.
              if (Gates.addProduct.allows(ref)) ...[
                SizedBox(width: context.getRSize(8)),
                _buildManageCategoriesButton(context),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildManageCategoriesButton(BuildContext context) {
    final t = Theme.of(context);
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        t.colorScheme.primary.withValues(alpha: 0.12);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    // Never under the 48dp target, however hard the scale compresses (#392).
    final side = math.max(context.getRSize(52), kMinInteractiveDimension);
    return Tooltip(
      message: 'Manage categories',
      child: Material(
        color: tint,
        borderRadius: radius,
        child: InkWell(
          key: const ValueKey('inventory-manage-categories'),
          onTap: () => showManageCategoriesSheet(context),
          borderRadius: radius,
          child: SizedBox.square(
            dimension: side,
            child: Center(
              child: AppIcon(
                AppIcons.tag,
                filled: true,
                size: context.getRSize(20),
                color: t.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = inventoryGutter(context, constraints.maxWidth);
        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, context.getRSize(12), gutter, 0),
          child: AppInput(
            controller: _searchCtrl,
            autofocus: true,
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
            hintText:
                'Search ${ref.watch(industryLexiconProvider).itemPluralLower}…',
            prefixIcon: AppIcon(
              AppIcons.search,
              size: context.getRSize(20),
              color: Theme.of(context).colorScheme.primary,
            ),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: AppIcon(
                      AppIcons.close,
                      size: context.getRSize(18),
                      color: _subtext,
                    ),
                    onPressed: () => setState(() {
                      _searchCtrl.clear();
                      _searchQuery = '';
                    }),
                  ),
          ),
        );
      },
    );
  }

  /// Days until [expiry] relative to today (negative = already expired).
  int _daysToExpiry(DateTime expiry) {
    final now = DateTime.now();
    return DateTime(
      expiry.year,
      expiry.month,
      expiry.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  /// A product is "flagged" when it has an expiry date that is past or within
  /// the next 30 days (master plan §16.4).
  bool _isNearExpiry(ProductData p) {
    final e = p.expiryDate;
    return e != null && _daysToExpiry(e) <= 30;
  }

  /// Stable sort that bubbles flagged (near/expired) products to the top,
  /// soonest expiry first; everything else keeps its incoming order.
  List<ProductDataWithStock> _sortNearExpiryFirst(
    List<ProductDataWithStock> list,
  ) {
    final flagged = <ProductDataWithStock>[];
    final rest = <ProductDataWithStock>[];
    for (final p in list) {
      (_isNearExpiry(p.product) ? flagged : rest).add(p);
    }
    if (flagged.isEmpty) return list;
    flagged.sort(
      (a, b) => _daysToExpiry(
        a.product.expiryDate!,
      ).compareTo(_daysToExpiry(b.product.expiryDate!)),
    );
    return [...flagged, ...rest];
  }

  /// The expiry pill's words on a flagged product row (§16.4), or null.
  String? _expiryLabel(ProductData product) {
    final e = product.expiryDate;
    if (e == null) return null;
    final days = _daysToExpiry(e);
    if (days < 0) return 'Expired';
    if (days <= 30) return days == 0 ? 'Expires today' : 'Expires in ${days}d';
    return null;
  }

  Widget _buildProductRow(
    BuildContext context,
    ProductDataWithStock item,
    String? categoryName, {
    required bool crates,
  }) {
    final product = item.product;
    final currentStock = item.totalStock;
    final isLow = currentStock > 0 && currentStock <= product.lowStockThreshold;
    final isOut = currentStock == 0;

    final expiry = product.expiryDate;

    return InventoryProductRow(
      // One complete product row is the unit the viewport tests assert on
      // (PRD #239): a starved list renders at zero height, shows nothing, and
      // reports no overflow, so "no red band" alone cannot catch it.
      key: inventoryProductRowKey(product.id),
      name: productDisplayName(
        product.name,
        product.size,
        unit: product.unit,
        crates: crates,
      ),
      subtitle: product.subtitle,
      categoryName: categoryName,
      photoPath: product.imagePath,
      stockLabel: currentStock.toString(),
      unit: unitLabel(product.unit, crates: crates),
      state: isOut
          ? InventoryStockState.out
          : (isLow ? InventoryStockState.low : InventoryStockState.ok),
      expiryLabel: _expiryLabel(product),
      expired: expiry != null && _daysToExpiry(expiry) < 0,
      // Long-press opens the full product editor (name/prices/details), so it
      // is gated on `products.edit_price` (hard rule #6/#7 — hide, don't
      // disable). Stock-only roles add stock via the product-detail Update
      // Stock sheet instead, never this editor.
      onLongPress: Gates.editProductPrice.allows(ref)
          ? () {
              HapticFeedback.mediumImpact();
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (ctx) => UpdateProductSheet(
                  product: product,
                  totalStock: currentStock,
                  onProductUpdated: (_) => setState(() {}),
                ),
              );
            }
          : null,
      onTap: () => openProductDetails(
        context,
        product,
        manufacturerName: _dbManufacturers
            .where((m) => m.id == product.manufacturerId)
            .map((m) => m.name)
            .firstOrNull,
        totalStock: item.totalStock.toDouble(),
        storeId: _selectedStoreId == 'all' ? null : _selectedStoreId,
        onUpdateStock: () => setState(() {}),
      ),
    );
  }

  // ── EMPTY CRATES TAB ───────────────────────────────────────────────────────
  List<Widget> _cratesTabSlivers(BuildContext context) {
    // §16.8.1 Phase 2: crate figures are PER-STORE when a store is active and
    // business-wide in "All Stores". Full bottles come from the active store's
    // inventory (fullCratesByManufacturerProvider). #159: empties are DERIVED
    // from the append-only crate_ledger for BOTH views — the per-store pool when
    // a store is locked (storeCrateBalancesProvider) and the business-wide pool
    // otherwise (emptyCratesByManufacturerProvider) — so the two views agree.
    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final fullByMfr =
        ref.watch(fullCratesByManufacturerProvider).valueOrNull ??
        const <String, int>{};
    final Map<String, int> emptyByMfr;
    if (lockedStoreId == null) {
      emptyByMfr =
          ref.watch(emptyCratesByManufacturerProvider).valueOrNull ??
          const <String, int>{};
    } else {
      emptyByMfr =
          ref.watch(storeCrateBalancesProvider).valueOrNull ??
          const <String, int>{};
    }

    final shortagesByMfr =
        ref.watch(crateShortagesByManufacturerProvider).valueOrNull ??
        const <String, int>{};

    final stats = _computeCrateStats(fullByMfr, emptyByMfr);
    int emptyForMfr(ManufacturerData mfr) => emptyByMfr[mfr.id] ?? 0;

    final trackedMfrIds =
        ref.watch(crateTrackedManufacturerIdsProvider).valueOrNull ??
        const <String>{};
    final crateManufacturers = [
      for (final mfr in _dbManufacturers)
        if (showsOnEmptyCrates(
          hasTrackedBottleProduct: trackedMfrIds.contains(mfr.id),
          emptyCount: emptyForMfr(mfr),
          shortCount: shortagesByMfr[mfr.id] ?? 0,
        ))
          mfr,
    ];

    final totalEmpty = emptyByMfr.values.fold<int>(0, (s, v) => s + v);
    final totalFull = stats.fold<int>(0, (s, e) => s + e.fullCratesEquiv);
    final gap = context.getRSize(12);

    return [
      _cappedSliver(
        top: context.getRSize(16),
        sliver: SliverList.list(
          children: [
            // 1. Stats Overview
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: InventoryFigureCard(
                      label: 'Empty In Stock',
                      value: totalEmpty.toString(),
                      icon: AppIcons.beerMug,
                      tone: IconTileTone.warning,
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: InventoryFigureCard(
                      label: 'Full (Crate)',
                      value: totalFull.toString(),
                      icon: AppIcons.wineBottle,
                      tone: IconTileTone.info,
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: context.getRSize(24)),

            // 2. Bottle manufacturers (#389): only brands with a tracked
            // bottle product, plus any brand still holding crates in this view.
            // Every manufacturer (and Add New) lives on the Manufacturers tab.
            const SectionHeader(title: 'Bottle manufacturers'),

            SizedBox(height: gap),

            // Same rule as the Suppliers tab: no "none yet" before the first
            // download has finished (#313).
            if (crateManufacturers.isEmpty &&
                ref.watch(firstDownloadInProgressProvider))
              const SizedBox.shrink()
            else if (crateManufacturers.isEmpty)
              const InventoryEmptyCard(
                icon: AppIcons.box,
                title: 'No bottle manufacturers yet',
                subtitle:
                    'A manufacturer shows here once it has a returnable bottle '
                    'product',
              )
            else
              ...crateManufacturers.map((mfr) {
                // stats is keyed by manufacturer ID, so match on mfr.id —
                // matching on mfr.name never hits and forced every card's
                // "Full" to 0.
                final stat = stats.firstWhere(
                  (s) => s.manufacturer == mfr.id,
                  orElse: () => ManufacturerCrateStats(
                    manufacturer: mfr.id,
                    totalBottles: 0,
                    emptyCrates: emptyForMfr(mfr),
                    totalValueKobo: 0,
                  ),
                );
                return Padding(
                  padding: EdgeInsets.only(bottom: gap),
                  child: _buildManufacturerCard(
                    context,
                    mfr,
                    stat,
                    emptyCount: emptyForMfr(mfr),
                    shortCount: shortagesByMfr[mfr.id] ?? 0,
                  ),
                );
              }),
          ],
        ),
      ),
    ];
  }

  Widget _buildManufacturerCard(
    BuildContext context,
    ManufacturerData mfr,
    ManufacturerCrateStats stat, {
    required int emptyCount,
    int shortCount = 0,
  }) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final depositNaira = mfr.depositAmountKobo / 100;
    final totalAssets = stat.fullCratesEquiv + emptyCount;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);

    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('$kManufacturerCardKeyPrefix${mfr.id}'),
          borderRadius: radius,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ManufacturerScreen(manufacturer: mfr),
              ),
            );
          },
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.all(context.getRSize(16)),
                child: Row(
                  children: [
                    const IconTile(
                      icon: AppIcons.manufacturer,
                      tone: IconTileTone.info,
                      size: 44,
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mfr.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.boldStyle(15).copyWith(color: _text),
                          ),
                          if (depositNaira > 0)
                            Text(
                              'Crate value: ${formatCurrency(depositNaira)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context
                                  .regularStyle(12)
                                  .copyWith(color: _subtext),
                            ),
                        ],
                      ),
                    ),
                    if (shortCount > 0) ...[
                      SizedBox(width: context.getRSize(8)),
                      TagPill(
                        key: ValueKey('mfr_shortage_badge_${mfr.id}'),
                        // Wording unchanged (the badge test reads it).
                        label: '⚠ $shortCount short',
                        tone: TagPillTone.warning,
                      ),
                    ],
                    SizedBox(width: context.getRSize(4)),
                    AppIcon(
                      AppIcons.chevronRight,
                      size: context.getRSize(22),
                      color: _subtext,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: t.dividerColor),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(12),
                ),
                child: Row(
                  children: [
                    _mfrSimpleStat(
                      context,
                      'Full',
                      stat.fullCratesEquiv.toString(),
                      t.colorScheme.primary,
                    ),
                    _mfrSimpleStat(
                      context,
                      'Empty',
                      emptyCount.toString(),
                      f.warning,
                    ),
                    _mfrSimpleStat(
                      context,
                      'Total',
                      totalAssets.toString(),
                      f.green,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mfrSimpleStat(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            style: context
                .semiBoldStyle(11)
                .copyWith(color: _subtext, letterSpacing: 0.5),
          ),
          SizedBox(height: context.getRSize(2)),
          Text(value, style: context.extraBoldStyle(18).copyWith(color: color)),
        ],
      ),
    );
  }
}
