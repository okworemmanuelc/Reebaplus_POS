import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/coach_hint_banner.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';

class ReceiveStockScreen extends ConsumerStatefulWidget {
  const ReceiveStockScreen({super.key});

  @override
  ConsumerState<ReceiveStockScreen> createState() => _ReceiveStockScreenState();
}

class _ReceiveStockScreenState extends ConsumerState<ReceiveStockScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// The one scroll view's controller: opening search scrolls back to the top
  /// so the field (the first sliver) is in view, as it was when it sat above
  /// the grid.
  final ScrollController _scrollController = ScrollController();

  List<ProductDataWithStock> _allProducts = [];
  List<CategoryData> _categories = [];
  String? _selectedCategoryId;
  String _searchQuery = '';
  bool _isSearching = false;
  bool _isLoading = true;
  bool _showReceiveHint = false;

  StreamSubscription? _productsSub;
  StreamSubscription? _categoriesSub;

  @override
  void initState() {
    super.initState();
    uiHintService.shouldShow(UiHintService.hintReceiveLongpress).then((show) {
      if (show && mounted) {
        setState(() => _showReceiveHint = true);
        // Count this display as a passive view so an ignored hint still retires
        // after `_retireAfter` visits (never shown forever).
        uiHintService.markShown(UiHintService.hintReceiveLongpress);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initStreams();
    });
  }

  @override
  void dispose() {
    _productsSub?.cancel();
    _categoriesSub?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initStreams() {
    final db = ref.read(databaseProvider);

    // The "Current: X" count on each card must match what the user sees in the
    // Inventory tab, so we mirror its display semantics exactly: a locked store
    // shows that store's on-hand stock; "All Stores" (no lock) shows the
    // aggregate across every store. Previously this fell back to the first
    // selectable store in All-Stores mode, so it showed only one store's stock
    // and diverged from Inventory. The receive WRITE target is resolved
    // separately at checkout (§15.7) — this only governs the displayed count.
    final storeId = ref.read(lockedStoreProvider).value;

    _categoriesSub = db.inventoryDao.watchAllCategories().listen((cats) {
      if (!mounted) return;
      setState(() {
        _categories = cats;
        // The chosen category was deleted (e.g. by sync): back to "All"
        // rather than a filter nothing can match (#394; the old lookup threw).
        if (_selectedCategoryId != null &&
            !cats.any((c) => c.id == _selectedCategoryId)) {
          _selectedCategoryId = null;
        }
      });
    });

    final productStream = storeId != null
        ? db.inventoryDao.watchProductDatasWithStockByStore(storeId)
        : db.inventoryDao.watchAllProductDatasWithStock();

    _productsSub = productStream.listen((products) {
      if (mounted) {
        setState(() {
          _allProducts = products;
          _isLoading = false;
        });
      }
    });
  }

  List<ProductDataWithStock> get _filteredProducts {
    var items = _allProducts.where((item) => !item.product.isDeleted).toList();

    if (_selectedCategoryId != null) {
      items = items
          .where((item) => item.product.categoryId == _selectedCategoryId)
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      items = items
          .where(
            (item) =>
                item.product.name.toLowerCase().contains(q) ||
                (item.product.subtitle?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    return items;
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _searchQuery = '';
      }
    });
    if (_isSearching && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // §14.7 / §16.7 — defense-in-depth route guard citing the same named gate
    // as the Inventory FAB that opens this screen (Gates.receiveStock). The
    // screen form waits for permissions to resolve (no denial flash) and renders
    // the standard no-access scaffold when denied — still blocking any
    // back-stack / deep-link reach for a Cashier (or Manager without either key).
    // Inside the flow the New Product card, price edits, and the supplier-payment
    // section are separately gated, so a stock keeper with only `stock.add` can
    // update quantities but can't create products, change prices, or record
    // payments.
    return Guarded.screen(
      gate: Gates.receiveStock,
      builder: (context) {
        final zeroStores = ref.watch(zeroStoresEmptySurfaceProvider);
        return DecoratedBox(
          decoration: AppDecorations.pageBackground(context),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: ReceiveTopBar(
              height: receiveTopBarHeight(context),
              icon: AppIcons.receiving,
              title: 'Receive Stock',
              // Whose stock the "Current" counts show: the locked store, or
              // the aggregate under All Stores.
              subtitle: ref.watch(activeStoreLabelProvider),
              actions: [
                ReceiveTopBarAction(
                  key: ReceiveKeys.searchToggle,
                  icon: _isSearching ? AppIcons.close : AppIcons.search,
                  tooltip: _isSearching ? 'Close search' : 'Search',
                  onPressed: _toggleSearch,
                ),
              ],
            ),
            bottomNavigationBar: zeroStores ? null : _buildBottomBar(context),
            body: SafeArea(
              child: zeroStores
                  ? const FirstRunEmptyState()
                  : _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : AppRefreshWrapper(child: _buildScroll(context)),
            ),
          ),
        );
      },
    );
  }

  /// One scroll view (PRD #239): search (while open) → category chips → the
  /// coach hint → the grid, so on a short screen the chrome scrolls away
  /// rather than starving the grid.
  Widget _buildScroll(BuildContext context) {
    final gutter = context.getRSize(16);
    final categoryNames = {for (final c in _categories) c.id: c.name};
    final selected = _selectedCategoryId == null
        ? null
        : _categories.where((c) => c.id == _selectedCategoryId).firstOrNull;
    return CustomScrollView(
      key: ReceiveKeys.scroll,
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (_isSearching)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, gutter, gutter, 0),
            sliver: SliverToBoxAdapter(child: _buildSearchField()),
          ),
        SliverPadding(
          padding: EdgeInsets.only(top: context.getRSize(12)),
          sliver: SliverToBoxAdapter(
            child: CategoryFilterBar(
              categories: ['All', ..._categories.map((c) => c.name)],
              selectedCategory: selected?.name ?? 'All',
              onCategorySelected: (name) {
                setState(() {
                  _selectedCategoryId = name == 'All'
                      ? null
                      : _categories
                            .where((c) => c.name == name)
                            .firstOrNull
                            ?.id;
                });
              },
            ),
          ),
        ),
        if (_showReceiveHint && Gates.editProductPrice.allows(ref))
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              0,
            ),
            sliver: SliverToBoxAdapter(
              // Only for roles that can edit price, as before.
              child: CoachHintBanner(
                key: ReceiveKeys.hint,
                message: 'Tap and hold a product to edit it.',
                onDismiss: () {
                  setState(() => _showReceiveHint = false);
                  // Deliberate close retires the hint immediately so it never
                  // reappears (was markShown, which let it surface a second
                  // time).
                  uiHintService.markDismissed(
                    UiHintService.hintReceiveLongpress,
                  );
                },
              ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: context.getRSize(16))),
        ReceiveProductGrid(
          products: _filteredProducts,
          categoryNames: categoryNames,
        ),
        SliverToBoxAdapter(child: SizedBox(height: gutter)),
      ],
    );
  }

  Widget _buildSearchField() {
    return AppInput(
      key: ReceiveKeys.search,
      controller: _searchController,
      autofocus: true,
      onChanged: (v) => setState(() => _searchQuery = v),
      hintText: 'Search products...',
      prefixIcon: Icon(AppIcons.search, size: context.getRSize(18)),
    );
  }

  /// "Review Items (N)" at the foot of the screen while the receipt has
  /// lines; the fly-to target for added products (#394).
  Widget _buildBottomBar(BuildContext context) {
    final cartLineCount = ref.watch(
      receiveCartProvider.select((lines) => lines.length),
    );

    if (cartLineCount == 0) return const SizedBox.shrink();

    final t = Theme.of(context);
    final gutter = context.getRSize(16);
    return Container(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(12),
        gutter,
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      // Clear of a side system inset (a landscape navigation bar, a cutout)
      // when nothing above has taken it out already.
      child: SafeArea(
        top: false,
        bottom: false,
        child: FlyTarget(
          id: FlyTargetId.receiveCart,
          child: AppButton(
            key: ReceiveKeys.reviewBar,
            text: 'Review Items ($cartLineCount)',
            icon: AppIcons.cart,
            isFullWidth: true,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ReceiveCartScreen()),
              );
            },
          ),
        ),
      ),
    );
  }
}
