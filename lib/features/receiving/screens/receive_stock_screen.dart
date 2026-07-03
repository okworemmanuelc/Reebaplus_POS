import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'dart:async';

class ReceiveStockScreen extends ConsumerStatefulWidget {
  const ReceiveStockScreen({super.key});

  @override
  ConsumerState<ReceiveStockScreen> createState() => _ReceiveStockScreenState();
}

class _ReceiveStockScreenState extends ConsumerState<ReceiveStockScreen> {
  final TextEditingController _searchController = TextEditingController();
  
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
      if (show && mounted) setState(() => _showReceiveHint = true);
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
      if (mounted) setState(() => _categories = cats);
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
      items = items.where((item) => item.product.categoryId == _selectedCategoryId).toList();
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
  }

  @override
  Widget build(BuildContext context) {
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final cardCol = Theme.of(context).cardColor;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;

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
      builder: (context) => Scaffold(
      backgroundColor: surfaceCol,
      appBar: AppBar(
        title: const Text('Receive Stock', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: surfaceCol,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(
              _isSearching ? FontAwesomeIcons.xmark.data : FontAwesomeIcons.magnifyingGlass.data,
              size: 17,
              color: subtextCol,
            ),
            onPressed: _toggleSearch,
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _buildBottomBar(context),
      body: SafeArea(
        child: Column(
          children: [
            if (_isSearching) _buildSearchField(surfaceCol, cardCol, textCol, subtextCol),
            if (!_isLoading)
              CategoryFilterBar(
                categories: ['All', ..._categories.map((c) => c.name)],
                selectedCategory: _selectedCategoryId == null
                    ? 'All'
                    : _categories.firstWhere((c) => c.id == _selectedCategoryId).name,
                onCategorySelected: (name) {
                  setState(() {
                    if (name == 'All') {
                      _selectedCategoryId = null;
                    } else {
                      _selectedCategoryId = _categories.firstWhere((c) => c.name == name).id;
                    }
                  });
                },
                textCol: textCol,
                borderCol: borderCol,
              ),
            if (!_isLoading &&
                _showReceiveHint &&
                Gates.editProductPrice.allows(ref))
              _buildReceiveHint(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : AppRefreshWrapper(
                      child: ReceiveProductGrid(
                        products: _filteredProducts,
                        cardCol: cardCol,
                        textCol: textCol,
                        subtextCol: subtextCol,
                        borderCol: borderCol,
                      ),
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  // Inline dismissible hint above the product grid telling stock receivers
  // how to edit a product. Mirrors the cart screen's "tap an item to edit"
  // banner; only shown to roles that can edit price.
  Widget _buildReceiveHint() {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(8),
        context.getRSize(20),
        0,
      ),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            FontAwesomeIcons.circleInfo.data,
            size: context.getRSize(16),
            color: primary,
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Text(
              'Tap and hold a product to edit it.',
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: primary,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              FontAwesomeIcons.xmark.data,
              size: context.getRSize(16),
              color: primary,
            ),
            onPressed: () {
              setState(() => _showReceiveHint = false);
              uiHintService.markShown(UiHintService.hintReceiveLongpress);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(Color surfaceCol, Color cardCol, Color textCol, Color subtextCol) {
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.fromLTRB(context.getRSize(16), 0, context.getRSize(16), context.getRSize(12)),
      child: AppInput(
        controller: _searchController,
        autofocus: true,
        onChanged: (v) => setState(() => _searchQuery = v),
        hintText: 'Search products...',
        prefixIcon: Icon(FontAwesomeIcons.magnifyingGlass.data, size: context.getRSize(16)),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final cartLineCount = ref.watch(receiveCartProvider.select((lines) => lines.length));
    
    if (cartLineCount == 0) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: AppButton(
        text: 'Review Items ($cartLineCount)',
        icon: FontAwesomeIcons.cartShopping.data,
        isFullWidth: true,
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ReceiveCartScreen()),
          );
        },
      ),
    );
  }
}
