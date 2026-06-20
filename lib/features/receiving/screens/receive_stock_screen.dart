import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
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

  StreamSubscription? _productsSub;
  StreamSubscription? _categoriesSub;

  @override
  void initState() {
    super.initState();
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
    final storeId = ref.read(lockedStoreProvider).value;
    
    // We must have a store ID to filter properly, fallback to first selectable if null
    final fallback = ref.read(selectableStoresProvider).firstOrNull?.id;
    final effectiveStoreId = storeId ?? fallback;

    _categoriesSub = db.inventoryDao.watchAllCategories().listen((cats) {
      if (mounted) setState(() => _categories = cats);
    });

    if (effectiveStoreId != null) {
      _productsSub = db.inventoryDao.watchProductDatasWithStockByStore(effectiveStoreId).listen((products) {
        if (mounted) {
          setState(() {
            _allProducts = products;
            _isLoading = false;
          });
        }
      });
    } else {
      // Unlikely edge case if user has no stores
      setState(() => _isLoading = false);
    }
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

    // §14.7 — defense-in-depth route guard. The split FAB that opens this screen
    // is already gated on `products.add` (CEO + Manager-with-permission); this
    // blocks any back-stack / deep-link reach for Cashier / Stock keeper /
    // Manager-without-permission.
    if (!hasPermission(ref, 'products.add')) {
      return Scaffold(
        backgroundColor: surfaceCol,
        appBar: AppBar(
          title: const Text('Receive Stock'),
          backgroundColor: surfaceCol,
          elevation: 0,
          centerTitle: true,
        ),
        body: Center(
          child: Text(
            "You don't have access to Receive Stock.",
            style: TextStyle(color: subtextCol),
          ),
        ),
      );
    }

    return Scaffold(
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
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(
        top: false,
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
      ),
    );
  }
}
