import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

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
import 'package:reebaplus_pos/shared/widgets/pin_dialog.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// Pure store-confinement filter (§11.2 / §28 multi-store). Given all active
/// [stores] and the set of store ids the user is [assigned] to, returns the
/// stores they may sell from. `assigned == null` means "may view every store"
/// (CEO, or a Manager the CEO granted all-stores) → all stores. A confined user
/// with no assignment falls back to all stores so POS never dead-ends on "no
/// store" (the §9.5 staff-assignment editor normally guarantees at least one).
List<StoreData> selectableStoresFor(
  List<StoreData> stores,
  Set<String>? assigned,
) {
  if (assigned == null) return stores;
  final mine = stores.where((s) => assigned.contains(s.id)).toList();
  return mine.isEmpty ? stores : mine;
}

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
      _initStore();
    });
  }

  /// The stores the current user may sell from (§11.2 confinement / §28
  /// multi-store): every active store for a CEO / all-stores Manager, otherwise
  /// only their assigned store(s). Reads the live stores stream first so it works
  /// on a cold start (the table fills after a fresh-login pull).
  Future<List<StoreData>> _confineToSelectable() async {
    final db = ref.read(databaseProvider);
    final all = await db.storesDao.watchActiveStores().first;
    final slug = ref.read(currentUserRoleProvider)?.slug;
    final canViewAllStores = slug == 'ceo' ||
        (slug == 'manager' && ref.read(managerCanViewAllStoresProvider));
    final userId = ref.read(authProvider).currentUser?.id;
    if (canViewAllStores || userId == null) return all;
    final assigned =
        (await db.userStoresDao.getForUser(userId)).map((s) => s.storeId).toSet();
    return selectableStoresFor(all, assigned);
  }

  Future<void> _initStore() async {
    final nav = ref.read(navigationProvider);
    final selectable = await _confineToSelectable();
    if (selectable.isEmpty || !mounted) return;

    // Keep an already-valid selection (sticky across POS re-entry within the
    // session). Only (re)default when the locked store is unset or isn't one the
    // user may sell from — e.g. a confined staff member whose lock still points
    // at the global first store, or a store they're no longer assigned to.
    final current = nav.lockedStoreId.value;
    if (current != null && selectable.any((s) => s.id == current)) return;

    // Default to the first selectable store so POS is immediately usable.
    // build() reads lockedStoreId via .read (a ValueNotifier, not watched), so
    // force one rebuild after locking it post-first-paint.
    nav.setLockedStore(selectable.first.id);
    setState(() {});

    // §28 "pick your store" gate: a confined staff member assigned to MORE THAN
    // one store confirms which one they're working from. One-time per session —
    // once a valid store is locked, the early-return above skips re-prompting.
    final slug = ref.read(currentUserRoleProvider)?.slug;
    final canViewAllStores = slug == 'ceo' ||
        (slug == 'manager' && ref.read(managerCanViewAllStoresProvider));
    if (!canViewAllStores && selectable.length > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final subtext = Theme.of(context).textTheme.bodySmall?.color ??
            Theme.of(context).iconTheme.color!;
        _showStorePicker(context, subtext);
      });
    }
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
    // §12.1 / §28: the store selector shows whenever the user has more than one
    // store they may sell from — every active store for a CEO / all-stores
    // Manager, otherwise their assigned store(s). Single-store users see no
    // switcher (nothing to switch).
    final slug = ref.watch(currentUserRoleProvider)?.slug;
    final canViewAllStores = slug == 'ceo' ||
        (slug == 'manager' && ref.watch(managerCanViewAllStoresProvider));
    final userId = ref.watch(authProvider).currentUser?.id;
    final allStores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final Set<String>? assignedIds = (canViewAllStores || userId == null)
        ? null
        : (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[])
            .map((s) => s.storeId)
            .toSet();
    final showStoreSwitcher =
        selectableStoresFor(allStores, assignedIds).length > 1;
    // §12.1: POS header shows the business name (live, so a Business Info
    // rename reflects here) with the current store as the subtitle.
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
        if (showStoreSwitcher)
          IconButton(
            icon: Icon(
              FontAwesomeIcons.store,
              size: 16,
              color: ref.read(navigationProvider).lockedStoreId.value == null
                  ? subtextCol
                  : Theme.of(context).colorScheme.primary,
            ),
            tooltip: 'Select Store',
            onPressed: () => _showStorePicker(context, subtextCol),
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
    // §12.3: Quick Sale needs CEO/Manager authority. CEO and Manager proceed
    // directly; a Cashier must enter a CEO or Manager PIN (their own PIN is
    // rejected).
    final slug = ref.read(currentUserRoleProvider)?.slug;
    if (slug != 'ceo' && slug != 'manager') {
      final approver = await PinDialog.show(context, title: 'Quick Sale');
      if (approver == null) return; // cancelled or wrong PIN
      // Resolve the approver's role straight from the DB. We can't use
      // `ref.read(userRoleProvider(approver.id))` here: that provider is backed
      // by stream providers, and for an id nothing on screen is watching, a cold
      // read returns null before the streams emit — which wrongly rejected a
      // valid CEO/Manager PIN. Awaiting the DAOs mirrors userRoleProvider's
      // membership → role resolution synchronously.
      final db = ref.read(databaseProvider);
      final memberships = await db.userBusinessesDao.getForUser(approver.id);
      String? approverSlug;
      if (memberships.isNotEmpty) {
        final roleId = memberships.first.roleId;
        final roles = await db.rolesDao.getAll();
        for (final r in roles) {
          if (r.id == roleId) {
            approverSlug = r.slug;
            break;
          }
        }
      }
      if (approverSlug != 'ceo' && approverSlug != 'manager') {
        if (!context.mounted) return;
        AppNotification.showError(context, 'Manager or CEO PIN required.');
        return;
      }
    }

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => QuickSaleModal(
        surfaceCol: Theme.of(context).colorScheme.surface,
        textCol: Theme.of(context).colorScheme.onSurface,
        subtextCol:
            (Theme.of(context).textTheme.bodySmall?.color ??
            Theme.of(context).iconTheme.color!),
        cardCol: Theme.of(context).cardColor,
        isDark: Theme.of(context).brightness == Brightness.dark,
      ),
    );
  }

  Future<void> _showStorePicker(
    BuildContext context,
    Color subtextCol,
  ) async {
    // Confined to the stores the user may sell from (§11.2): a non-CEO sees only
    // their assigned store(s), never the whole business's stores.
    final stores = await _confineToSelectable();
    if (!context.mounted) return;
    final surface = Theme.of(context).colorScheme.surface;
    final text = Theme.of(context).colorScheme.onSurface;
    final border = Theme.of(context).dividerColor;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.only(
            bottom: ctx.deviceBottomInset + 20,
            top: 10,
            left: 20,
            right: 20,
          ),
          decoration: BoxDecoration(
            color: surface.withValues(alpha: 0.85),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: border.withValues(alpha: 0.5), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 20,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Stylish Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: subtextCol.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      FontAwesomeIcons.store,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Switch Store',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: text,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  // Scrolls within the sheet when there are more stores than
                  // fit — otherwise the fixed grid overflows the bottom.
                  physics: const ClampingScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.3,
                  ),
                  itemCount: stores.length,
                  itemBuilder: (ctx, i) {
                    final w = stores[i];
                    final isSelected =
                        ref.read(navigationProvider).lockedStoreId.value == w.id;
                    return InkWell(
                      onTap: () {
                        ref.read(navigationProvider).setLockedStore(w.id);
                        Navigator.pop(ctx);
                        setState(() {});
                      },
                      borderRadius: BorderRadius.circular(20),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.08)
                              : (Theme.of(context).dividerColor),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? blueMain
                                : border.withValues(alpha: 0.3),
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.15),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : [],
                        ),
                        child: Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Icon(
                                    FontAwesomeIcons.buildingCircleCheck,
                                    size: 22,
                                    color: isSelected
                                        ? blueMain
                                        : subtextCol.withValues(alpha: 0.5),
                                  ),
                                  Text(
                                    w.name,
                                    style: TextStyle(
                                      color: text,
                                      fontSize: 14,
                                      fontWeight: isSelected
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                      letterSpacing: -0.2,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Positioned(
                                top: 12,
                                right: 12,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
