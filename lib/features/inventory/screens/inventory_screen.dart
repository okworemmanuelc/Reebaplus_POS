import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart'; // RESPONSIVE: utility imported
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_group.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_history_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/shared/widgets/skeletons/first_load_skeletons.dart';

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
  String _stockFilter = 'all'; // 'all' | 'low' | 'out' | 'expiry'
  List<ProductDataWithStock> _dbProducts = [];
  List<ManufacturerData> _dbManufacturers = [];
  List<CategoryData> _dbCategories = [];
  String? _selectedCategoryId;
  // Products-tab header search (§16.4, amended — reuses the POS toggle pattern).
  bool _showSearch = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();
  int _totalCrateAssetsSum = 0;
  List<CrateSizeGroupData> _dbCrateSizeGroups = [];

  bool _isFirstLoad = true;
  StreamSubscription<List<ProductDataWithStock>>? _productsSub;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  StreamSubscription<List<CategoryData>>? _categoriesSub;
  StreamSubscription<List<CrateSizeGroupData>>? _crateSizeGroupsSub;
  StreamSubscription<int>? _emptyCratesSumSub;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  List<CrateSizeGroupData> get _activeCrateSizeGroups =>
      _dbCrateSizeGroups.where((cg) => cg.emptyCrateStock > 0).toList();

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
    // `suppliers.manage` wouldn't change the visible tabs. The grants watch above
    // stays only as the load-gate so the tab bar still reveals in one shot.
    final perms = ref.watch(currentUserPermissionsProvider);
    final showSuppliers = perms.contains('suppliers.manage');
    final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
    final showHistory =
        role.slug == 'ceo' ||
        role.slug == 'manager' ||
        role.slug == 'stock_keeper';

    return [
      'products',
      if (showSuppliers) 'suppliers',
      if (showCrates) 'crates',
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
    'history' => 'History',
    _ => 'Products',
  };

  Widget _tabBody(BuildContext context, String key) => switch (key) {
    'suppliers' => _buildSuppliersTab(context),
    'crates' => _buildCratesTab(context),
    'history' => InventoryHistoryTab(
      storeId: _selectedStoreId == 'all' ? null : _selectedStoreId,
    ),
    _ => _buildProductsTab(context),
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

    // Defer all DB stream subscriptions until after the first frame so the
    // shimmer skeleton renders immediately without competing with 8+ SQL
    // queries on the Drift background isolate.
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
        if (mounted) setState(() => _dbCategories = data);
      }, onError: (e) => debugPrint('Error watching categories: $e'));

      // Per-manufacturer full/empty crate figures are read reactively in the
      // Crates tab via fullCratesByManufacturerProvider /
      // storeCrateBalancesProvider so they re-scope to the active store
      // (§16.8.1 Phase 2) without re-plumbing imperative subscriptions.

      _crateSizeGroupsSub = db.inventoryDao.watchAllCrateSizeGroups().listen((
        data,
      ) {
        if (mounted) setState(() => _dbCrateSizeGroups = data);
      });
    });
  }

  @override
  void dispose() {
    _productsSub?.cancel();
    _manufacturersSub?.cancel();
    _categoriesSub?.cancel();
    _crateSizeGroupsSub?.cancel();
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
    // (§16.7). The drawer item and bottom-nav Stock tab already hide without it;
    // this guards a deep-link / programmatic switch to the tab. SharedScaffold
    // keeps the drawer + bottom nav so the user can navigate away.
    if (!hasPermission(ref, 'stock.view')) {
      return SharedScaffold(
        activeRoute: 'inventory',
        backgroundColor: _bg,
        appBar: AppBar(
          title: const Text(
            'Inventory',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
        ),
        body: Center(
          child: Text(
            'You don\'t have access to Inventory.',
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    // First load: show the inventory skeleton (brief §4.4) while the store is
    // empty and products are still streaming in, then resolve to the real list.
    if (ref.watch(firstLoadSkeletonActiveProvider)) {
      return SharedScaffold(
        activeRoute: 'inventory',
        backgroundColor: _bg,
        appBar: _buildAppBar(context),
        body: const SafeArea(child: InventorySkeleton()),
      );
    }

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
    // Receive Stock FAB — open to anyone who can add stock (stock keepers, §16.7)
    // or add products. Inside the flow, creating a NEW product is separately
    // gated on `products.add` (the New Product card) and price edits on their own
    // permissions, so a stock keeper with only `stock.add` can receive/update
    // quantities but can't create products or change prices.
    final canReceiveStock =
        hasPermission(ref, 'stock.add') || hasPermission(ref, 'products.add');

    return SharedScaffold(
      activeRoute: 'inventory',
      backgroundColor: _bg,
      appBar: _buildAppBar(context),
      floatingActionButton: (onProductsTab && canReceiveStock)
          ? AppFAB(
              label: 'Receive Stock',
              icon: FontAwesomeIcons.plus.data,
              reserveBottomInset: false,
              onPressed: () {
                Navigator.of(context).push(slideDownRoute(const ReceiveStockScreen()));
              },
            )
          : null,
      body: SafeArea(
        top: false,
        child: !tabsReady
            ? const Center(child: CircularProgressIndicator())
            : AppRefreshWrapper(
                child: NestedScrollView(
                  headerSliverBuilder: (context, innerBoxIsScrolled) {
                    return [
                      SliverToBoxAdapter(child: _buildSummaryCards(context)),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _StickyTabBarDelegate(
                          child: _buildTabBar(context),
                        ),
                      ),
                    ];
                  },
                  body: TabBarView(
                    controller: _tabController,
                    children: [
                      for (final key in _tabKeys) _tabBody(context, key),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      leading: context.isDesktop ? null : const MenuButton(),
      title: AppBarHeader(
        icon: FontAwesomeIcons.boxesStacked.data,
        title: 'Inventory',
        subtitle: ref.watch(activeStoreLabelProvider),
      ),
      actions: [
        // Search toggle — only meaningful on the Products tab (§16.4).
        if (_currentTab == 0)
          IconButton(
            tooltip: _showSearch ? 'Close search' : 'Search products',
            icon: Icon(_showSearch ? Icons.close : Icons.search),
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
        if (const {
              'ceo',
              'manager',
              'stock_keeper',
            }.contains(ref.watch(currentUserRoleProvider)?.slug) &&
            hasPermission(ref, 'stock.adjust'))
          IconButton(
            tooltip: 'Daily Stock Count',
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => Navigator.push(
              context,
              slideDownRoute(
                StockCountScreen(
                  storeId: ref.read(navigationProvider).lockedStoreId.value,
                ),
              ),
            ),
          ),
        const NotificationBell(),
        const SizedBox(width: AppSpacing.s),
      ],
    );
  }

  Widget _buildSummaryCards(BuildContext context) {
    if (_isFirstLoad) return const SizedBox.shrink();
    final products = _dbProducts;

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

    final cards = [
      _summaryCard(
        context,
        'Total SKUs',
        '$totalItems',
        FontAwesomeIcons.layerGroup.data,
        Theme.of(context).colorScheme.primary,
        isActive: _stockFilter == 'all',
        onTap: () => setState(() {
          _stockFilter = 'all';
          _tabController.animateTo(0);
        }),
      ),
      _summaryCard(
        context,
        'Low Stock',
        '$lowStock',
        FontAwesomeIcons.triangleExclamation.data,
        AppColors.warning,
        isActive: _stockFilter == 'low',
        onTap: () => setState(() {
          _stockFilter = 'low';
          _tabController.animateTo(0);
        }),
      ),
      _summaryCard(
        context,
        'Out of Stock',
        '$outOfStock',
        FontAwesomeIcons.ban.data,
        danger,
        isActive: _stockFilter == 'out',
        onTap: () => setState(() {
          _stockFilter = 'out';
          _tabController.animateTo(0);
        }),
      ),
      // Total Crates only when the Empty Crates tab is visible (Bar / Beer
      // distributor — §16.10). Jumps to that tab by its dynamic index.
      if (_tabKeys.contains('crates'))
        _summaryCard(
          context,
          'Total Crates',
          '${totalCrates.toInt()}',
          FontAwesomeIcons.beerMugEmpty.data,
          success,
          isActive: _currentTab == _tabKeys.indexOf('crates'),
          onTap: () => setState(() {
            _tabController.animateTo(_tabKeys.indexOf('crates'));
          }),
        ),
      // Near Expiry — last card; available for all business types (§16.5).
      // Tapping filters the Products list to flagged items, which already
      // sort soonest-expiry first.
      _summaryCard(
        context,
        'Near Expiry',
        '$nearExpiry',
        FontAwesomeIcons.hourglassHalf.data,
        AppColors.warning,
        isActive: _stockFilter == 'expiry',
        onTap: () => setState(() {
          _stockFilter = 'expiry';
          _tabController.animateTo(0);
        }),
      ),
    ];

    return Container(
      color: _surface,
      padding: EdgeInsets.only(
        top: context.getRSize(8),
        bottom: context.getRSize(10),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.spacingM),
        child: Row(
          children: cards.asMap().entries.map((entry) {
            final int index = entry.key;
            final Widget card = entry.value;
            return Container(
              width: context.isPhone
                  ? context.getRSize(108)
                  : context.getRSize(150),
              margin: EdgeInsets.only(
                right: index < cards.length - 1 ? context.getRSize(10) : 0,
              ),
              child: card,
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _summaryCard(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color, {
    bool isActive = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(context.getRSize(10)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(context.radiusM),
          border: Border.all(
            color: isActive ? color : color.withValues(alpha: 0.2),
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: context.getRSize(13), color: color),
                SizedBox(width: context.getRSize(6)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: rFontSize(context, 16),
                      fontWeight: FontWeight.w800,
                      color: _text,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(4)),
            Text(
              label,
              style: context.bodySmall.copyWith(
                color: _subtext,
                fontWeight: FontWeight.w600,
                fontSize: context.getRFontSize(11),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: _subtext,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: context.getRFontSize(13),
        ),
        unselectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: context.getRFontSize(13),
        ),
        indicatorColor: Theme.of(context).colorScheme.primary,
        indicatorWeight: 3,
        tabs: [for (final key in _tabKeys) Tab(text: _tabLabel(key))],
      ),
    );
  }

  Widget _buildProductsTab(BuildContext context) {
    if (_isFirstLoad) {
      return const Center(child: CircularProgressIndicator());
    }

    var list = _dbProducts;

    if (_stockFilter == 'low') {
      list = list
          .where(
            (p) =>
                p.totalStock > 0 && p.totalStock <= p.product.lowStockThreshold,
          )
          .toList();
    } else if (_stockFilter == 'out') {
      list = list.where((p) => p.totalStock == 0).toList();
    } else if (_stockFilter == 'expiry') {
      list = list.where((p) => _isNearExpiry(p.product)).toList();
    }

    if (_selectedManufacturer != 'all') {
      final mfrId = _dbManufacturers
          .where((m) => m.name == _selectedManufacturer)
          .map((m) => m.id)
          .firstOrNull;
      list = list.where((p) => p.product.manufacturerId == mfrId).toList();
    }
    if (_selectedCategoryId != null) {
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

    return Column(
      children: [
        if (_showSearch) _buildSearchField(context),
        _buildSupplierFilter(context),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    'No products matching filters',
                    style: TextStyle(color: _subtext),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    context.getRSize(12),
                    context.getRSize(16),
                    context.getRSize(120) + context.bottomInset,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _buildProductRow(context, list[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildSuppliersTab(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: AppButton(
            text: 'Add Supplier',
            variant: AppButtonVariant.secondary,
            icon: FontAwesomeIcons.plus.data,
            onPressed: _showAddSupplierDialog,
          ),
        ),
        Expanded(
          child: ref.read(supplierServiceProvider).getAll().isEmpty
              ? Center(
                  child: Text(
                    'No suppliers added yet',
                    style: TextStyle(color: _subtext),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    0,
                    context.getRSize(16),
                    context.getRSize(120) + context.bottomInset,
                  ),
                  itemCount: ref.read(supplierServiceProvider).getAll().length,
                  itemBuilder: (_, i) {
                    final s = ref.read(supplierServiceProvider).getAll()[i];
                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              SupplierDetailScreen(supplierId: s.id),
                        ),
                      ).then((_) => setState(() {})),
                      child: Container(
                        margin: EdgeInsets.only(bottom: context.getRSize(12)),
                        padding: EdgeInsets.all(context.getRSize(16)),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _border),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: context.getRSize(48),
                              height: context.getRSize(48),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                FontAwesomeIcons.buildingColumns.data,
                                color: Theme.of(context).colorScheme.primary,
                                size: context.getRSize(20),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: context.getRFontSize(16),
                                      color: _text,
                                    ),
                                  ),
                                  if (s.contactDetails.isNotEmpty) ...[
                                    SizedBox(height: context.getRSize(4)),
                                    Text(
                                      s.contactDetails,
                                      style: TextStyle(
                                        color: _subtext,
                                        fontSize: context.getRFontSize(13),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: _subtext,
                              size: context.getRSize(20),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Build the per-manufacturer crate stats (keyed by manufacturer id) from the
  /// active-store full/empty maps resolved in [_buildCratesTab].
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
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(16),
      ),
      color: _surface,
      child: Row(
        children: [
          // Category dropdown (§16.4, amended): replaces the old chip row,
          // drives `_selectedCategoryId`. The store is now picked in the nav bar.
          Expanded(
            child: _isFirstLoad
                ? const SizedBox.shrink()
                : AppDropdown<String>(
                    value: _selectedCategoryId ?? 'all',
                    labelText: 'Category',
                    items: [
                      DropdownMenuItem(
                        value: 'all',
                        child: Text('All', style: TextStyle(color: _text)),
                      ),
                      ..._dbCategories.map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _text),
                          ),
                        ),
                      ),
                    ],
                    onChanged: (val) => setState(
                      () => _selectedCategoryId = (val == null || val == 'all')
                          ? null
                          : val,
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
                        child: Text('All', style: TextStyle(color: _text)),
                      ),
                      ..._dbManufacturers.map(
                        (m) => DropdownMenuItem(
                          value: m.name,
                          child: Text(m.name, style: TextStyle(color: _text)),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setState(() => _selectedManufacturer = val ?? 'all'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Container(
      color: _surface,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        0,
      ),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        onChanged: (v) => setState(() => _searchQuery = v.trim()),
        style: TextStyle(color: _text, fontSize: context.getRFontSize(14)),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search products…',
          prefixIcon: Icon(Icons.search, size: 18, color: _subtext),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.clear, size: 18, color: _subtext),
                  onPressed: () => setState(() {
                    _searchCtrl.clear();
                    _searchQuery = '';
                  }),
                ),
          filled: true,
          fillColor: Theme.of(context).cardColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _border),
          ),
        ),
      ),
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

  /// Small expiry chip shown on a flagged product row (§16.4).
  Widget? _expiryChip(BuildContext context, ProductData product) {
    final e = product.expiryDate;
    if (e == null) return null;
    final days = _daysToExpiry(e);
    String label;
    Color color;
    if (days < 0) {
      label = 'Expired';
      color = danger;
    } else if (days <= 30) {
      label = days == 0 ? 'Expires today' : 'Expires in ${days}d';
      color = AppColors.warning;
    } else {
      return null;
    }
    return Container(
      margin: EdgeInsets.only(top: context.getRSize(4)),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(2),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.getRFontSize(10),
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildProductRow(BuildContext context, ProductDataWithStock item) {
    final product = item.product;
    final currentStock = item.totalStock;
    final isLow = currentStock > 0 && currentStock <= product.lowStockThreshold;
    final isOut = currentStock == 0;

    Color statusColor = success;
    String statusLabel = 'In Stock';
    if (isOut) {
      statusColor = danger;
      statusLabel = 'Out of Stock';
    } else if (isLow) {
      statusColor = AppColors.warning;
      statusLabel = 'Low Stock';
    }

    final accent = product.colorHex != null
        ? Color(int.parse(product.colorHex!.replaceFirst('#', '0xFF')))
        : Theme.of(context).colorScheme.primary;

    return GestureDetector(
      // Long-press opens the full product editor (name/prices/details), so it
      // is gated on `products.edit_price` (hard rule #6/#7 — hide, don't
      // disable). Stock-only roles add stock via the product-detail Update
      // Stock sheet instead, never this editor.
      onLongPress: hasPermission(ref, 'products.edit_price')
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
      onTap: () {
        final inventoryItem = InventoryItem(
          id: product.id.toString(),
          productName: product.name,
          subtitle: product.subtitle ?? '',
          icon: productIconFromCodePoint(product.iconCodePoint),
          color: accent,
          storeStock: {'w1': item.totalStock.toDouble()},
          lowStockThreshold: product.lowStockThreshold.toDouble(),
          retailerPrice: product.retailerPriceKobo / 100.0,
          wholesalerPrice: product.wholesalerPriceKobo / 100.0,
          buyingPrice: product.buyingPriceKobo / 100.0,
          category: product.categoryId?.toString(),
          manufacturer: _dbManufacturers
              .where((m) => m.id == product.manufacturerId)
              .map((m) => m.name)
              .firstOrNull,
          size: product.size,
          unit: product.unit,
        );
        Navigator.push(
          context,
          slideDownRoute<void>(
            ProductDetailScreen(
              item: inventoryItem,
              onUpdateStock: () => setState(() {}),
              selectedStoreId: _selectedStoreId == 'all'
                  ? null
                  : _selectedStoreId,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: context.spacingS),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isOut
                ? Theme.of(context).colorScheme.error.withValues(alpha: 0.3)
                : (isLow
                      ? const Color(0xFFF59E0B).withValues(alpha: 0.3)
                      : _border),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(10)),
          child: Row(
            children: [
              Container(
                width: context.getRSize(52),
                height: context.getRSize(52),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  productIconFromCodePoint(product.iconCodePoint),
                  color: accent,
                  size: context.getRSize(24),
                ),
              ),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            productDisplayName(
                              product.name,
                              product.size,
                              unit: product.unit,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: context.getRFontSize(15),
                              color: _text,
                            ),
                          ),
                        ),
                        SizedBox(width: context.getRSize(8)),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.getRSize(8),
                            vertical: context.getRSize(2),
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: context.getRFontSize(10),
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (product.subtitle != null) ...[
                      SizedBox(height: context.getRSize(4)),
                      Text(
                        product.subtitle!,
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          color: _subtext,
                        ),
                      ),
                    ],
                    if (_expiryChip(context, product) case final chip?)
                      Align(alignment: Alignment.centerLeft, child: chip),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      currentStock.toString(),
                      style: TextStyle(
                        fontSize: context.getRFontSize(22),
                        fontWeight: FontWeight.w800,
                        color: isOut
                            ? danger
                            : (isLow ? AppColors.warning : _text),
                      ),
                    ),
                  ),
                  Text(
                    product.unit,
                    style: TextStyle(
                      fontSize: context.getRFontSize(11),
                      color: _subtext,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── CRATES TAB REDESIGNED ──────────────────────────────────────────────────
  Widget _buildCratesTab(BuildContext context) {
    // §16.8.1 Phase 2: crate figures are PER-STORE when a store is active and
    // business-wide in "All Stores". Full bottles come from the active store's
    // inventory (fullCratesByManufacturerProvider); empties come from that
    // store's store_crate_balances, falling back to the business-wide
    // manufacturers.empty_crate_stock when no store is locked.
    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final fullByMfr =
        ref.watch(fullCratesByManufacturerProvider).valueOrNull ??
        const <String, int>{};
    final Map<String, int> emptyByMfr;
    if (lockedStoreId == null) {
      emptyByMfr = {for (final m in _dbManufacturers) m.id: m.emptyCrateStock};
    } else {
      final balances =
          ref.watch(storeCrateBalancesProvider).valueOrNull ??
          const <StoreCrateBalanceData>[];
      emptyByMfr = {for (final b in balances) b.manufacturerId: b.balance};
    }

    final stats = _computeCrateStats(fullByMfr, emptyByMfr);
    int emptyForMfr(ManufacturerData mfr) => emptyByMfr[mfr.id] ?? 0;

    final totalEmpty = emptyByMfr.values.fold<int>(0, (s, v) => s + v);
    final totalFull = stats.fold<int>(0, (s, e) => s + e.fullCratesEquiv);

    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(120) + context.bottomInset,
      ),
      children: [
        // 1. Stats Overview
        _buildCrateStatsRow(
          context,
          totalEmpty: totalEmpty,
          totalFull: totalFull,
        ),

        SizedBox(height: context.getRSize(24)),

        // 2. Manufacturers Section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Manufacturers',
              style: TextStyle(
                fontSize: context.getRFontSize(18),
                fontWeight: FontWeight.w800,
                color: _text,
                letterSpacing: -0.5,
              ),
            ),
            AppButton(
              text: 'Add New',
              icon: FontAwesomeIcons.circlePlus.data,
              variant: AppButtonVariant.ghost,
              isFullWidth: false,
              onPressed: _showAddManufacturerDialog,
            ),
          ],
        ),

        SizedBox(height: context.getRSize(12)),

        if (_dbManufacturers.isEmpty)
          _buildEmptyCratesState(
            context,
            'No manufacturers to track',
            'Add your first manufacturer above',
          )
        else
          ..._dbManufacturers.map((mfr) {
            // stats is keyed by manufacturer ID, so match on mfr.id — matching
            // on mfr.name never hits and forced every card's "Full" to 0.
            final stat = stats.firstWhere(
              (s) => s.manufacturer == mfr.id,
              orElse: () => ManufacturerCrateStats(
                manufacturer: mfr.id,
                totalBottles: 0,
                emptyCrates: emptyForMfr(mfr),
                totalValueKobo: 0,
              ),
            );
            return _buildManufacturerCard(
              context,
              mfr,
              stat,
              emptyCount: emptyForMfr(mfr),
            );
          }),

        if (_activeCrateSizeGroups.isNotEmpty) ...[
          SizedBox(height: context.getRSize(24)),
          _buildCrateGroupAssets(context),
        ],
      ],
    );
  }

  Widget _buildCrateStatsRow(
    BuildContext context, {
    required int totalEmpty,
    required int totalFull,
  }) {
    return Row(
      children: [
        Expanded(
          child: _miniCrateStatCard(
            context,
            'Empty In Stock',
            totalEmpty.toString(),
            FontAwesomeIcons.beerMugEmpty.data,
            AppColors.warning,
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: _miniCrateStatCard(
            context,
            'Full (Crate)',
            totalFull.toString(),
            FontAwesomeIcons.wineBottle.data,
            Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _miniCrateStatCard(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(6)),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: context.getRSize(12), color: color),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            value,
            style: TextStyle(
              fontSize: context.getRFontSize(22),
              fontWeight: FontWeight.w900,
              color: _text,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.bold,
              color: _subtext,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildManufacturerCard(
    BuildContext context,
    ManufacturerData mfr,
    ManufacturerCrateStats stat, {
    required int emptyCount,
  }) {
    final depositNaira = mfr.depositAmountKobo / 100;
    final totalAssets = stat.fullCratesEquiv + emptyCount;

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            offset: const Offset(0, 4),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: Row(
              children: [
                Container(
                  width: context.getRSize(44),
                  height: context.getRSize(44),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    FontAwesomeIcons.industry.data,
                    color: Theme.of(context).colorScheme.secondary,
                    size: context.getRSize(16),
                  ),
                ),
                SizedBox(width: context.getRSize(14)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mfr.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: context.getRFontSize(15),
                          color: _text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (depositNaira > 0)
                        Text(
                          'Deposit: ${formatCurrency(depositNaira)}',
                          style: TextStyle(
                            color: _subtext,
                            fontSize: context.getRFontSize(11),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
                _manageMfrButton(context, mfr, emptyCount: emptyCount),
              ],
            ),
          ),
          Divider(height: 1, color: _border),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(16),
              vertical: context.getRSize(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _mfrSimpleStat(
                  context,
                  'Full',
                  stat.fullCratesEquiv.toString(),
                  Theme.of(context).colorScheme.primary,
                ),
                _mfrSimpleStat(
                  context,
                  'Empty',
                  emptyCount.toString(),
                  AppColors.warning,
                ),
                _mfrSimpleStat(
                  context,
                  'Total',
                  totalAssets.toString(),
                  AppColors.success,
                  isBold: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mfrSimpleStat(
    BuildContext context,
    String label,
    String value,
    Color color, {
    bool isBold = false,
  }) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: context.getRFontSize(9),
            fontWeight: FontWeight.w900,
            color: _subtext,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: context.getRFontSize(16),
            fontWeight: isBold ? FontWeight.w900 : FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _manageMfrButton(
    BuildContext context,
    ManufacturerData mfr, {
    required int emptyCount,
  }) {
    return InkWell(
      onTap: () => _showUpdateManufacturerDialog(mfr, emptyCount: emptyCount),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(12),
          vertical: context.getRSize(8),
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'Manage',
          style: TextStyle(
            fontSize: context.getRFontSize(11),
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCratesState(
    BuildContext context,
    String title,
    String subtitle,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(32)),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(
              FontAwesomeIcons.boxOpen.data,
              size: context.getRSize(32),
              color: _border,
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold, color: _text),
            ),
            Text(subtitle, style: TextStyle(fontSize: 12, color: _subtext)),
          ],
        ),
      ),
    );
  }

  void _showAddManufacturerDialog() {
    final nameCtrl = TextEditingController();
    final stockCtrl = TextEditingController(text: '0');
    final depositCtrl = TextEditingController(text: '0');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + ctx.deviceBottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add Manufacturer',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: _text,
              ),
            ),
            const SizedBox(height: 20),
            _styledDialogField(nameCtrl, 'Name', 'e.g. Nigerian Breweries'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _styledDialogField(
                    stockCtrl,
                    'Initial Empty',
                    '0',
                    isNumber: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _styledDialogField(
                    depositCtrl,
                    'Deposit ($activeCurrencySymbol)',
                    '0',
                    isNumber: true,
                    isCurrency: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            AppButton(
              text: 'Add Manufacturer',
              variant: AppButtonVariant.primary,
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                final mfrName = nameCtrl.text.trim();
                final mfrBusinessId = ref
                    .read(authProvider)
                    .currentUser
                    ?.businessId;
                if (mfrBusinessId == null) return;
                try {
                  await ref
                      .read(databaseProvider)
                      .inventoryDao
                      .insertManufacturer(
                        ManufacturersCompanion.insert(
                          name: mfrName,
                          businessId: mfrBusinessId,
                          emptyCrateStock: Value(
                            int.tryParse(stockCtrl.text.trim()) ?? 0,
                          ),
                          depositAmountKobo: Value(
                            ((parseCurrency(depositCtrl.text)) * 100).round(),
                          ),
                        ),
                      );
                  await ref
                      .read(activityLogProvider)
                      .logAction(
                        'add_manufacturer',
                        '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} added manufacturer: $mfrName',
                      );
                  if (context.mounted) Navigator.pop(ctx);
                } catch (_) {
                  if (ctx.mounted) {
                    AppNotification.showError(
                      ctx,
                      'Could not add manufacturer. Please try again.',
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showUpdateManufacturerDialog(
    ManufacturerData mfr, {
    required int emptyCount,
  }) {
    final stockCtrl = TextEditingController(text: emptyCount.toString());
    final depositCtrl = TextEditingController();
    final crateValueCtrl = TextEditingController();
    const isCEO = true;

    // Default modes
    String depositMode = 'change'; // 'add' | 'change'
    String priceMode = 'change'; // 'add' | 'change'

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setB) => Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + ctx.deviceBottomPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Update ${mfr.name}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _text,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _styledDialogField(
                stockCtrl,
                'Empty Crates In Stock',
                'e.g. 50',
                isNumber: true,
              ),
              const SizedBox(height: 12),

              // Deposit Amount with CEO Check
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Deposit Amount ($activeCurrencySymbol)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _subtext,
                        ),
                      ),
                      Row(
                        children: [
                          _modeChip(
                            'Add',
                            depositMode == 'add',
                            () => setB(() => depositMode = 'add'),
                          ),
                          const SizedBox(width: 4),
                          _modeChip(
                            'Change',
                            depositMode == 'change',
                            () => setB(() => depositMode = 'change'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _styledDialogField(
                    depositCtrl,
                    '',
                    depositMode == 'add' ? 'Amount to add' : 'New total amount',
                    isNumber: true,
                    isCurrency: true,
                    readOnly: !isCEO,
                    showLabel: false,
                  ),
                ],
              ),

              if (isCEO) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                FontAwesomeIcons.shieldHalved.data,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'CEO: CRATE PRICE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              _modeChip(
                                'Add',
                                priceMode == 'add',
                                () => setB(() => priceMode = 'add'),
                                small: true,
                              ),
                              const SizedBox(width: 4),
                              _modeChip(
                                'Change',
                                priceMode == 'change',
                                () => setB(() => priceMode = 'change'),
                                small: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _styledDialogField(
                        crateValueCtrl,
                        'Bulk Update Price ($activeCurrencySymbol)',
                        priceMode == 'add'
                            ? '+ /- amount'
                            : 'New price for all items',
                        isNumber: true,
                        isCurrency: true,
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 32),
              AppButton(
                text: 'Save Changes',
                variant: AppButtonVariant.primary,
                onPressed: () async {
                  final db = ref.read(databaseProvider);
                  try {
                    // Update Stock
                    await db.inventoryDao.updateManufacturerStock(
                      mfr.id,
                      int.tryParse(stockCtrl.text.trim()) ?? emptyCount,
                      storeId: ref.read(lockedStoreProvider).value,
                    );

                    // Update Deposit
                    if (isCEO && depositCtrl.text.isNotEmpty) {
                      final inputVal = parseCurrency(depositCtrl.text);
                      final inputKobo = (inputVal * 100).round();
                      int newDepositKobo = mfr.depositAmountKobo;
                      if (depositMode == 'add') {
                        newDepositKobo += inputKobo;
                      } else {
                        newDepositKobo = inputKobo;
                      }
                      await db.inventoryDao.updateManufacturerDeposit(
                        mfr.id,
                        newDepositKobo,
                      );
                    }

                    // Update Product Crate Values
                    if (isCEO && crateValueCtrl.text.isNotEmpty) {
                      final inputVal = parseCurrency(crateValueCtrl.text);
                      final inputKobo = (inputVal * 100).round();

                      if (priceMode == 'add') {
                        await db.catalogDao.updateManufacturerEmptyCrateValue(
                          mfr.id,
                          inputKobo,
                        );
                      } else {
                        await db.catalogDao.updateManufacturerEmptyCrateValue(
                          mfr.id,
                          inputKobo,
                        );
                      }
                    }

                    await ref
                        .read(activityLogProvider)
                        .logAction(
                          'update_manufacturer',
                          '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} updated crate stock/deposit for ${mfr.name}',
                        );
                    if (context.mounted) Navigator.pop(ctx);
                  } catch (_) {
                    if (ctx.mounted) {
                      AppNotification.showError(
                        ctx,
                        'Could not save changes. Please try again.',
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeChip(
    String label,
    bool active,
    VoidCallback onTap, {
    bool small = false,
  }) {
    final color = active ? Theme.of(context).colorScheme.primary : _subtext;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 8 : 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? color : _border, width: 1.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: small ? 9 : 10,
            fontWeight: FontWeight.w900,
            color: active ? color : _subtext,
          ),
        ),
      ),
    );
  }

  Widget _styledDialogField(
    TextEditingController ctrl,
    String label,
    String hint, {
    bool isNumber = false,
    bool isCurrency = false,
    bool readOnly = false,
    bool showLabel = true,
  }) {
    return AppInput(
      controller: ctrl,
      labelText: showLabel ? label : null,
      hintText: hint,
      readOnly: readOnly,
      keyboardType: isNumber
          ? (isCurrency
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.number)
          : TextInputType.text,
      inputFormatters: isCurrency
          ? [CurrencyInputFormatter()]
          : (isNumber ? [FilteringTextInputFormatter.digitsOnly] : null),
      fillColor: Theme.of(context).cardColor,
    );
  }

  Widget _buildCrateGroupAssets(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: EdgeInsets.all(context.getRSize(8)),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                FontAwesomeIcons.box.data,
                size: context.getRSize(14),
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
            SizedBox(width: context.getRSize(10)),
            Text(
              'Crate Size Group Assets',
              style: TextStyle(
                fontSize: context.getRFontSize(16),
                fontWeight: FontWeight.bold,
                color: _text,
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: context.isTablet ? 3 : 2,
            mainAxisExtent: context.getRSize(120),
            crossAxisSpacing: context.getRSize(12),
            mainAxisSpacing: context.getRSize(12),
          ),
          itemCount: _activeCrateSizeGroups.length,
          itemBuilder: (context, i) {
            final grp = _activeCrateSizeGroups[i];
            return Container(
              padding: EdgeInsets.all(context.getRSize(16)),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    grp.name,
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.bold,
                      color: _text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${grp.crateSizeLabel[0].toUpperCase()}${grp.crateSizeLabel.substring(1)}',
                    style: TextStyle(
                      fontSize: context.getRFontSize(11),
                      color: _subtext,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        grp.emptyCrateStock.toString(),
                        style: TextStyle(
                          fontSize: context.getRFontSize(20),
                          fontWeight: FontWeight.w900,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _showUpdateCrateGroupDialog(grp),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: _border,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.edit, size: 14, color: _text),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _showUpdateCrateGroupDialog(CrateSizeGroupData grp) {
    final stockCtrl = TextEditingController(
      text: grp.emptyCrateStock.toString(),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + ctx.deviceBottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Update ${grp.name}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _text,
              ),
            ),
            const SizedBox(height: 20),
            _styledDialogField(
              stockCtrl,
              'Physical Stock',
              '0',
              isNumber: true,
            ),
            const SizedBox(height: 24),
            AppButton(
              text: 'Save Changes',
              variant: AppButtonVariant.primary,
              onPressed: () async {
                final newStock =
                    int.tryParse(stockCtrl.text.trim()) ?? grp.emptyCrateStock;
                try {
                  await ref
                      .read(databaseProvider)
                      .inventoryDao
                      .updateCrateGroupStock(grp.id, newStock);
                  await ref
                      .read(activityLogProvider)
                      .logAction(
                        'crate_group_update',
                        '${ref.read(authProvider).currentUser?.name ?? 'Unknown'} set ${grp.name} crate stock to $newStock',
                      );
                  if (context.mounted) Navigator.pop(ctx);
                } catch (_) {
                  if (ctx.mounted) {
                    AppNotification.showError(
                      ctx,
                      'Could not update crate stock. Please try again.',
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }


  void _showAddSupplierDialog() {
    final nameCtrl = TextEditingController();
    final contactCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + ctx.deviceBottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Add New Supplier',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Only select for crate / bottle products',
              style: TextStyle(fontSize: 11, color: _subtext),
            ),
            const SizedBox(height: 20),
            _styledDialogField(
              nameCtrl,
              'Supplier / Company Name',
              'e.g. SABMiller Nigeria',
            ),
            const SizedBox(height: 16),
            _styledDialogField(
              contactCtrl,
              'Contact Details / Rep Info',
              'e.g. John Doe, 08012345678',
            ),
            const SizedBox(height: 32),
            AppButton(
              text: 'Add Supplier',
              variant: AppButtonVariant.primary,
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) return;
                final newSupplier = Supplier(
                  id: 's${DateTime.now().millisecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  crateGroup: CrateGroup.nbPlc,
                  trackInventory: true,
                  contactDetails: contactCtrl.text.trim(),
                  amountPaid: 0.0,
                  supplierAccountBalance: 0.0,
                );
                ref.read(supplierServiceProvider).addSupplier(newSupplier);
                await ref
                    .read(activityLogProvider)
                    .logAction(
                      'new_supplier',
                      'Supplier added: ${newSupplier.name}',
                    );
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _StickyTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _StickyTabBarDelegate({required this.child});
  @override
  double get minExtent => 48;
  @override
  double get maxExtent => 48;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(_StickyTabBarDelegate oldDelegate) {
    return child != oldDelegate.child;
  }
}
