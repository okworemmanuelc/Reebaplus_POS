import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/controllers/pos_controller.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/features/pos/widgets/category_filter_bar.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

class PosHomeScreen extends ConsumerStatefulWidget {
  const PosHomeScreen({super.key});

  @override
  ConsumerState<PosHomeScreen> createState() => _PosHomeScreenState();
}

class _PosHomeScreenState extends ConsumerState<PosHomeScreen> {
  PosController? _controller;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      setState(() {
        _controller = PosController(
          database: ref.read(databaseProvider),
          navigationService: ref.read(navigationProvider),
          cartService: ref.read(cartProvider),
        );
      });
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    // §12 / hard rule #6: POS is gated to roles that hold `sales.make` (CEO,
    // Manager, Cashier). Stock keeper is already hidden in the sidebar; this is
    // defense-in-depth against deep-links / bottom-nav.
    if (!hasPermission(ref, 'sales.make')) {
      return SharedScaffold(
        activeRoute: 'pos',
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Text(
              'You don\'t have access to Point of Sale.',
              style: TextStyle(
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    if (_controller == null) {
      final bgCol = Theme.of(context).scaffoldBackgroundColor;
      return SharedScaffold(
        activeRoute: 'pos',
        backgroundColor: bgCol,
        body: const SafeArea(
          child: SizedBox.shrink(),
        ),
      );
    }

    // §12.1: POS always sells from one concrete store. Keep the controller's
    // "All Stores" fallback in sync with the user's first selectable store so the
    // grid + checkout have a real store even when the global active store is
    // "All Stores" (an all-stores viewer's null). Deferred to post-frame because
    // setFallbackStore can re-subscribe + notify.
    final selectable = ref.watch(selectableStoresProvider);
    final fallback = selectable.isNotEmpty ? selectable.first.id : null;
    if (_controller!.fallbackStoreId != fallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller?.setFallbackStore(fallback);
      });
    }

    return ListenableBuilder(
      listenable: _controller!,
      builder: (context, _) {
            final bgCol = Theme.of(context).scaffoldBackgroundColor;
            final surfaceCol = Theme.of(context).colorScheme.surface;
            final cardCol = Theme.of(context).cardColor;
            final textCol = Theme.of(context).colorScheme.onSurface;
            final subtextCol =
                Theme.of(context).textTheme.bodySmall?.color ??
                Theme.of(context).iconTheme.color!;
            final borderCol = Theme.of(context).dividerColor;

            return SharedScaffold(
              activeRoute: 'pos',
              backgroundColor: bgCol,
              appBar: _buildAppBar(context, surfaceCol, textCol, subtextCol),
              floatingActionButton: context.isPhone
                  ? _buildCartFab(context)
                  : null,
              body: SafeArea(
                top: false,
                child: Column(
                  children: [
                    _buildHeader(
                      context,
                      surfaceCol,
                      textCol,
                      subtextCol,
                      borderCol,
                    ),
                    if (_controller!.isSearching)
                      _buildSearchField(
                        surfaceCol,
                        cardCol,
                        textCol,
                        subtextCol,
                      ),
                    _controller!.isLoading
                        ? const SizedBox.shrink()
                        : CategoryFilterBar(
                            categories: [
                              'All',
                              ..._controller!.categories.map((c) => c.name),
                            ],
                            selectedCategory:
                                _controller!.selectedCategoryId == null
                                ? 'All'
                                : _controller!.categories
                                      .firstWhere(
                                        (c) =>
                                            c.id ==
                                            _controller!.selectedCategoryId,
                                      )
                                      .name,
                            onCategorySelected: (name) {
                              if (name == 'All') {
                                _controller!.selectCategory(null);
                              } else {
                                final cat = _controller!.categories.firstWhere(
                                  (c) => c.name == name,
                                );
                                _controller!.selectCategory(cat.id);
                              }
                            },
                            textCol: textCol,
                            borderCol: borderCol,
                          ),
                    Expanded(
                      // ...
                      child: _controller!.isLoading
                          ? const SizedBox.shrink()
                          : TweenAnimationBuilder<double>(
                              // §12.5: subtle fade-in for content, no spinner.
                              tween: Tween(begin: 0, end: 1),
                              duration: const Duration(milliseconds: 250),
                              builder: (_, v, child) =>
                                  Opacity(opacity: v, child: child),
                              child: AppRefreshWrapper(
                                child: ProductGrid(
                                  products: _controller!.filteredProducts,
                                  onProductTap: (item) =>
                                      _addToCart(context, item),
                                  cardCol: cardCol,
                                  textCol: textCol,
                                  subtextCol: subtextCol,
                                  borderCol: borderCol,
                                  controller: _controller!,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
  ) {
    // §12.1: the store selector now lives in the navigation drawer (above Home),
    // not on the POS header. POS just reflects the active store: the header
    // subtitle shows the store it's selling from (the controller's current store
    // name, which already resolves the "All Stores" fallback). POS header shows
    // the business name (live, so a Business Info rename reflects here) with the
    // current store as the subtitle.
    final bizName = ref.watch(currentBusinessNameProvider);
    return AppBar(
      backgroundColor: surfaceCol,
      elevation: 0,
      leading: const MenuButton(),
      title: AppBarHeader(
        icon: FontAwesomeIcons.beerMugEmpty,
        title: bizName.isNotEmpty ? bizName : 'Reebaplus POS',
        subtitle: _controller!.currentStoreName ?? 'Point of Sale',
      ),
      actions: [
        IconButton(
          icon: Icon(
            _controller!.isSearching
                ? FontAwesomeIcons.xmark
                : FontAwesomeIcons.magnifyingGlass,
            size: 17,
            color: subtextCol,
          ),
          onPressed: () {
            _controller!.toggleSearch();
            if (!_controller!.isSearching) _searchController.clear();
          },
        ),
        const NotificationBell(),
        SizedBox(width: context.getRSize(16)),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
    Color borderCol,
  ) {
    // §12.2: CEO/Manager switch price tier freely; Cashier is locked to
    // Retailer (a selected wholesaler customer still auto-applies via the
    // controller's customer listener).
    final slug = ref.watch(currentUserRoleProvider)?.slug;
    final canSwitchTier = slug == 'ceo' || slug == 'manager';
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: _controller!.isLoading
                ? const SizedBox.shrink()
                : IgnorePointer(
                    ignoring: !canSwitchTier,
                    child: Opacity(
                      opacity: canSwitchTier ? 1.0 : 0.6,
                      child: AppDropdown<PriceTier>(
                        value: _controller!.selectedGroup,
                        items: const [
                          DropdownMenuItem(
                            value: PriceTier.retailer,
                            child: Text('Retailer'),
                          ),
                          DropdownMenuItem(
                            value: PriceTier.wholesaler,
                            child: Text('Wholesaler'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) _controller!.selectGroup(val);
                        },
                      ),
                    ),
                  ),
          ),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            flex: 5,
            child: _controller!.isLoading
                ? const SizedBox.shrink()
                : AppDropdown<String>(
                    value: _controller!.selectedManufacturerId,
                    items: [
                      const DropdownMenuItem(value: 'All', child: Text('All')),
                      ..._controller!.manufacturers.map(
                        (m) => DropdownMenuItem(
                          value: m.id.toString(),
                          child: Text(m.name),
                        ),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) _controller!.selectManufacturer(val);
                    },
                  ),
          ),
          SizedBox(width: context.getRSize(12)),
          _buildQuickSaleBtn(context),
        ],
      ),
    );
  }

  Widget _buildQuickSaleBtn(BuildContext context) {
    return GestureDetector(
      onTap: () => _showQuickSaleModal(context),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(10),
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(
          FontAwesomeIcons.bolt,
          size: context.getRSize(18),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildCartFab(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ref.read(cartProvider),
      builder: (context, cartItems, _) {
        if (cartItems.isEmpty) return const SizedBox.shrink();

        final double totalQty = cartItems.fold(
          0.0,
          (sum, item) => sum + (item['qty'] as num).toDouble(),
        );
        final String badgeText = totalQty == totalQty.roundToDouble()
            ? totalQty.toInt().toString()
            : totalQty.toStringAsFixed(1);

        return AppFAB(
          // POS is a bottom-nav tab root — the visible bottom bar already lifts
          // the FAB above the system nav; don't add the inset.
          reserveBottomInset: false,
          onPressed: () {
            ref.read(navigationProvider).setIndex(8); // 8 = CartScreen (9 is Deliveries)
          },
          icon: FontAwesomeIcons.cartShopping,
          label: 'Go to Cart',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchField(
    Color surfaceCol,
    Color cardCol,
    Color textCol,
    Color subtextCol,
  ) {
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        0,
        context.getRSize(16),
        context.getRSize(12),
      ),
      child: AppInput(
        controller: _searchController,
        autofocus: true,
        onChanged: (v) => _controller!.updateSearch(v),
        hintText: 'Search products...',
        prefixIcon: Icon(
          FontAwesomeIcons.magnifyingGlass,
          size: context.getRSize(16),
        ),
      ),
    );
  }

  void _addToCart(BuildContext context, ProductDataWithStock item) {
    final accepted = ref.read(cartProvider).addItem(
          item.product,
          qty: 1.0,
          maxStock: item.totalStock,
          tier: _controller!.selectedGroup,
        );
    if (accepted) {
      AppNotification.showSuccess(
        context,
        '${item.product.name} added to cart',
      );
    } else {
      AppNotification.showError(
        context,
        'Stock limit reached for ${item.product.name}',
      );
    }
  }

  Future<void> _showQuickSaleModal(BuildContext context) async {
    // §12.3 / §12.3.1: CEO and Manager add a Quick Sale straight to the cart.
    // A role below Manager no longer enters a PIN — the modal records an
    // approval request and waits for a Manager/CEO to approve it (the item then
    // drops into the cart) or reject it (the modal closes).
    final slug = ref.read(currentUserRoleProvider)?.slug;
    final requireApproval = slug != 'ceo' && slug != 'manager';

    showDialog(
      context: context,
      // While waiting for approval the modal must not be dismissable by tapping
      // outside — the pending request is withdrawn explicitly via Cancel/back.
      barrierDismissible: !requireApproval,
      builder: (ctx) => QuickSaleModal(
        surfaceCol: Theme.of(context).colorScheme.surface,
        textCol: Theme.of(context).colorScheme.onSurface,
        subtextCol:
            (Theme.of(context).textTheme.bodySmall?.color ??
            Theme.of(context).iconTheme.color!),
        cardCol: Theme.of(context).cardColor,
        isDark: Theme.of(context).brightness == Brightness.dark,
        requireApproval: requireApproval,
      ),
    );
  }

}
