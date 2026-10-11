import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/data/services/customer_service.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/crates/cart_crate_lines.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/features/pos/widgets/cart/cart_parts.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/features/pos/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/cart_line.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/cart_crate_sync.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:flutter/services.dart';

/// Key prefix on every cart line, so a viewport test can assert a *complete*
/// line is laid out and hit-testable (PRD #239's second assertion — a list
/// starved to zero height reports no overflow at all).
const String kCartLineKeyPrefix = 'cart-line-';

/// The key on one cart line. A line is identified by product id AND name, as
/// `CartService.addItem` merges them: Quick Sale lines carry no product id.
ValueKey<String> cartLineKey({
  required String? productId,
  required String name,
}) => ValueKey<String>('$kCartLineKeyPrefix${productId ?? ''}-$name');

class CartScreen extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> cart;
  final Customer? activeCustomer;
  final Function(Customer?) onCustomerChanged;
  final VoidCallback? onCheckoutSuccess;

  /// Set only when this screen is hosted in the app frame's cart panel
  /// (#352): adds the panel's ✕ to the end of the header, so the panel needs
  /// no extra strip (and no second status-bar band) above it.
  final VoidCallback? onClosePanel;

  const CartScreen({
    super.key,
    required this.cart,
    this.activeCustomer,
    required this.onCustomerChanged,
    this.onCheckoutSuccess,
    this.onClosePanel,
  });

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen>
    with SingleTickerProviderStateMixin {
  Customer? _activeCustomer;
  List<ManufacturerData> _manufacturers = [];
  List<StoreData> _stores = [];
  late final CartService _cart;
  late final CartCrateSync _crateSync;

  // ── Clear animation ──
  late AnimationController _clearCtrl;
  bool _isClearing = false;
  List<Map<String, dynamic>> _animatingItems = [];
  bool _showCartHint = false;

  static const _cgColors = [
    Color(0xFFF59E0B),
    Color(0xFF334155),
    Color(0xFFEF4444),
    Color(0xFF8B5CF6),
    Color(0xFF6366F1),
    Color(0xFF0EA5E9),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
  ];

  @override
  void initState() {
    super.initState();
    _activeCustomer = widget.activeCustomer;
    _clearCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _cart = ref.read(cartProvider);
    final db = ref.read(databaseProvider);
    // Keep the cart's crate config reconciled against the catalogue for as long
    // as this screen lives. This screen is built ONCE into the main layout's
    // tab stack, so it never re-runs initState after an Inventory edit — the
    // reconciler's live query is what carries a brand deposit change back here.
    _crateSync = ref.read(cartCrateSyncProvider)..start();
    _cart.addListener(_onCartChanged);
    _cart.activeCustomer.addListener(_onActiveCustomerChanged);
    db.storesDao.getActiveStores().then((ws) {
      if (mounted) setState(() => _stores = ws);
    });
    db.inventoryDao.watchAllManufacturers().listen((data) {
      if (mounted) setState(() => _manufacturers = data);
    });
    uiHintService.shouldShow(UiHintService.hintCartTapEdit).then((show) {
      if (show && mounted) {
        setState(() => _showCartHint = true);
        uiHintService.markShown(UiHintService.hintCartTapEdit);
      }
    });
  }

  @override
  void dispose() {
    _cart.removeListener(_onCartChanged);
    _cart.activeCustomer.removeListener(_onActiveCustomerChanged);
    _clearCtrl.dispose();
    super.dispose();
  }

  void _onCartChanged() {
    if (mounted) setState(() {});
  }

  void _onActiveCustomerChanged() {
    if (mounted) {
      setState(
        () => _activeCustomer = ref.read(cartProvider).activeCustomer.value,
      );
    }
  }

  Future<void> _clearWithAnimation() async {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final cart = ref.read(cartProvider);
    if (cart.value.isEmpty) return;
    setState(() {
      _isClearing = true;
      _animatingItems = List<Map<String, dynamic>>.from(cart.value);
    });
    _clearCtrl.reset();
    await _clearCtrl.forward();
    cart.clear();
    if (mounted) setState(() => _isClearing = false);
  }

  /// Proceed to Checkout. Reconciles the cart's crate config against the
  /// catalogue one last time before the quote is built.
  ///
  /// [CartCrateSync] already keeps the cart fresh through a live query, so this
  /// almost always no-ops. It exists for the frame-tight case: an edit
  /// committed on another device (or another tab) that the stream has not
  /// delivered yet when Checkout is tapped. CheckoutPage snapshots `cart`,
  /// `crateLines` and `total` at construction and never re-reads them, so a
  /// value that moves after this point cannot be corrected on that page.
  ///
  /// When something did move, stay on the cart and let it rebuild with the new
  /// figures — the cashier confirms what they are about to charge instead of
  /// being pushed onto a checkout screen quoting numbers they never saw. This
  /// mirrors how the price-staleness prompt returns to the cart.
  Future<void> _goToCheckout() async {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final bool moved;
    try {
      moved = await _crateSync.sync();
    } catch (e, st) {
      // §33.4 — never let a pre-flight read kill the checkout button. Record it
      // and go on with the figures on screen: the live query has been feeding
      // this cart all along, so they are the best available.
      CrashReporter.record(e, st, context: 'pos.cart.crate_preflight');
      if (mounted) _openCheckout();
      return;
    }
    if (!mounted) return;
    if (moved) {
      AppNotification.showInfo(
        context,
        'Crate values updated. Review the cart and check out again.',
      );
      return;
    }
    _openCheckout();
  }

  void _openCheckout() {
    // Rebuilt from the live cart rather than captured in `build`, so the values
    // pushed to checkout are the ones that survived the pre-flight above.
    // Sorted by quantity for checkout only: its order summary and the order it
    // writes list lines largest first, as before (the cart itself keeps the
    // order the lines were added).
    final items = List<Map<String, dynamic>>.from(ref.read(cartProvider).value)
      ..sort((a, b) => b['qty'].compareTo(a['qty']));
    final quote = _quote(
      items,
      isCrate: businessTracksCrates(ref.read(currentBusinessProvider)),
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutPage(
          cart: items,
          subtotal: quote.subtotal,
          crateLines: quote.crateLines,
          total: quote.total,
          customer: _activeCustomer,
          onCheckoutSuccess: widget.onCheckoutSuccess,
        ),
      ),
    );
  }

  Future<void> _saveCurrentCart() async {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final cart = ref.read(cartProvider);
    if (cart.value.isEmpty) {
      AppNotification.showError(context, 'Cannot save an empty cart');
      return;
    }

    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Cart'),
        content: AppInput(
          controller: nameController,
          autofocus: true,
          labelText: 'Cart Name',
          hintText: 'e.g. Morning Order',
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(context),
          ),
          AppButton(
            text: 'Save',
            variant: AppButtonVariant.primary,
            isFullWidth: false,
            onPressed: () => Navigator.pop(context, nameController.text),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      final cartJson = jsonEncode(cart.value);
      try {
        await ref
            .read(databaseProvider)
            .ordersDao
            .saveCart(
              SavedCartsCompanion.insert(
                name: name,
                customerId: drift.Value(_activeCustomer?.id),
                cartData: cartJson,
                cashierId: drift.Value(ref.read(authProvider).currentUser?.id),
                // Tag the store this cart was saved under (§12.1) so recall
                // restores it into the right store's bucket. null = "All Stores".
                storeId: drift.Value(
                  ref.read(navigationProvider).lockedStoreId.value,
                ),
                createdAt: drift.Value(DateTime.now()),
                businessId:
                    ref.read(authProvider).currentUser?.businessId ?? '',
              ),
            );
        if (mounted) {
          AppNotification.showSuccess(context, 'Cart saved successfully');
        }
      } catch (e, st) {
        CrashReporter.record(e, st, context: 'pos.cart.save');
        if (mounted) {
          AppNotification.showError(context, 'Could not save cart: $e');
        }
      }
    }
  }

  void _viewSavedCarts() {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final db = ref.read(databaseProvider);
    final custSvc = ref.read(customerServiceProvider);
    final cartSvc = ref.read(cartProvider);
    final cashierId = ref.read(authProvider).currentUser?.id;
    // Opportunistically purge expired carts (§13.5) before showing the list.
    db.ordersDao.deleteExpiredCarts();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        final muted = _subtext;
        final fixed =
            Theme.of(modalCtx).extension<AppFixedColors>() ??
            AppFixedColors.light;
        return Container(
          key: const Key('cart-saved-carts-sheet'),
          height: modalCtx.sheetMaxHeight(0.7),
          decoration: salesSheetDecoration(modalCtx),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  modalCtx.getRSize(20),
                  modalCtx.getRSize(12),
                  modalCtx.getRSize(12),
                  modalCtx.getRSize(12),
                ),
                child: SalesSheetHeader(
                  title: 'Saved Carts',
                  leading: const IconTile(icon: AppIcons.history, size: 44),
                  trailing: [
                    SalesBackButton(
                      icon: AppIcons.close,
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(modalCtx),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<SavedCartData>>(
                  stream: db.ordersDao.watchSavedCarts(
                    cashierId,
                    storeId: ref.read(navigationProvider).lockedStoreId.value,
                  ),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final carts = snapshot.data!;
                    if (carts.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const IconTile(
                              icon: AppIcons.history,
                              tone: IconTileTone.neutral,
                              size: 56,
                            ),
                            SizedBox(height: modalCtx.getRSize(10)),
                            Text(
                              'No saved carts found',
                              style: modalCtx
                                  .semiBoldStyle(14)
                                  .copyWith(color: muted),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        modalCtx.getRSize(20),
                        0,
                        modalCtx.getRSize(20),
                        modalCtx.deviceBottomPadding + modalCtx.getRSize(20),
                      ),
                      itemCount: carts.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: modalCtx.getRSize(8)),
                      itemBuilder: (context, index) {
                        final cart = carts[index];
                        final radius = BorderRadius.circular(
                          AppSpacing.borderRadiusL,
                        );
                        return DecoratedBox(
                          decoration: AppDecorations.card(
                            context,
                            radius: AppSpacing.borderRadiusL,
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: InkWell(
                              borderRadius: radius,
                              onTap: () async {
                                await _recallSavedCart(
                                  cart,
                                  modalCtx: modalCtx,
                                  custSvc: custSvc,
                                  cartSvc: cartSvc,
                                );
                              },
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  modalCtx.getRSize(12),
                                  modalCtx.getRSize(8),
                                  modalCtx.getRSize(4),
                                  modalCtx.getRSize(8),
                                ),
                                child: Row(
                                  children: [
                                    const IconTile(
                                      icon: AppIcons.cart,
                                      size: 40,
                                    ),
                                    SizedBox(width: modalCtx.getRSize(10)),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            cart.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: modalCtx
                                                .boldStyle(15)
                                                .copyWith(color: _text),
                                          ),
                                          Text(
                                            'Saved on ${cart.createdAt.toString().split('.')[0]}',
                                            style: modalCtx
                                                .regularStyle(12)
                                                .copyWith(color: muted),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete',
                                      constraints: const BoxConstraints(
                                        minWidth: kMinInteractiveDimension,
                                        minHeight: kMinInteractiveDimension,
                                      ),
                                      icon: AppIcon(
                                        AppIcons.delete,
                                        size: modalCtx.getRSize(22),
                                        color: fixed.danger,
                                      ),
                                      onPressed: () async {
                                        try {
                                          await db.ordersDao.deleteSavedCart(
                                            cart.id,
                                          );
                                        } catch (e, st) {
                                          CrashReporter.record(
                                            e,
                                            st,
                                            context: 'pos.cart.delete_saved',
                                          );
                                          if (!mounted) return;
                                          AppNotification.showError(
                                            this.context,
                                            'Could not delete saved cart: $e',
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Loads [cart] from the Saved Carts sheet (unchanged from before #393; moved
  /// out of the sheet builder so the restyled row can call it).
  Future<void> _recallSavedCart(
    SavedCartData cart, {
    required BuildContext modalCtx,
    required CustomerService custSvc,
    required CartService cartSvc,
  }) async {
    try {
      final items = (jsonDecode(cart.cartData) as List)
          .cast<Map<String, dynamic>>();
      Customer? customer;
      if (cart.customerId != null) {
        customer = custSvc.getById(cart.customerId!);
      }
      cartSvc.loadCart(items, customer, storeId: cart.storeId);
      Navigator.pop(modalCtx);
      AppNotification.showSuccess(context, 'Cart loaded');
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'pos.cart.load_saved');
      if (!mounted) return;
      Navigator.pop(modalCtx);
      AppNotification.showError(context, 'Could not load this saved cart.');
    }
  }

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _primary => Theme.of(context).colorScheme.primary;

  void _showChangeCustomerModal() {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    // Default picker store — lone owner picks from POS lock.
    final String? defaultPickerStoreId = ref
        .read(navigationProvider)
        .lockedStoreId
        .value;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Fixed-height sheet (no DraggableScrollableSheet): the drag-resize was
      // the source of the jank — scrolling had to hand off to "expand the
      // sheet" before the list actually moved, and the 75%↔95% snap jumped.
      // A fixed height means the list scrolls cleanly. enableDrag stays off so
      // a downward scroll never doubles as drag-to-dismiss; close via the
      // native barrier (tap-outside, smooth slide-down) or the X.
      enableDrag: false,
      builder: (modalCtx) {
        String searchQuery = '';
        String? pickerStoreId = defaultPickerStoreId;
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final muted = _subtext;
            return SizedBox(
              key: const Key('cart-customer-picker'),
              height: modalCtx.sheetMaxHeight(0.85),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      modalCtx.getRSize(20),
                      modalCtx.getRSize(12),
                      modalCtx.getRSize(12),
                      0,
                    ),
                    child: SalesSheetHeader(
                      title: 'Select Customer',
                      leading: const IconTile(icon: AppIcons.user, size: 44),
                      trailing: [
                        // Creating a customer needs `customers.add`
                        // (hard rule #6/#7) — hide "New" otherwise.
                        // The AddCustomerSheet save handler re-checks
                        // the same key at the write boundary.
                        if (Gates.addCustomer.allows(ref)) ...[
                          AppButton(
                            key: const Key('cart-picker-new'),
                            text: 'New',
                            variant: AppButtonVariant.secondary,
                            isFullWidth: false,
                            height: kMinInteractiveDimension,
                            icon: AppIcons.userAdd,
                            onPressed: () {
                              Navigator.pop(modalCtx);
                              AddCustomerSheet.show(
                                context,
                                onCustomerAdded: (newCustomer) {
                                  setState(() => _activeCustomer = newCustomer);
                                  widget.onCustomerChanged(newCustomer);
                                  ref
                                      .read(cartProvider)
                                      .setActiveCustomer(newCustomer);
                                },
                              );
                            },
                          ),
                          SizedBox(width: modalCtx.getRSize(4)),
                        ],
                        SalesBackButton(
                          icon: AppIcons.close,
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(modalCtx),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: modalCtx.getRSize(12)),
                  // ── Store filter ──
                  if (_stores.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        modalCtx.getRSize(20),
                        0,
                        modalCtx.getRSize(20),
                        modalCtx.getRSize(8),
                      ),
                      child: AppDropdown<String?>(
                        value: pickerStoreId,
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              'All Stores',
                              style: modalCtx
                                  .semiBoldStyle(13)
                                  .copyWith(color: _primary),
                            ),
                          ),
                          ..._stores.map(
                            (w) => DropdownMenuItem<String?>(
                              value: w.id,
                              child: Text(
                                w.name,
                                overflow: TextOverflow.ellipsis,
                                style: modalCtx
                                    .semiBoldStyle(13)
                                    .copyWith(color: _primary),
                              ),
                            ),
                          ),
                        ],
                        onChanged: (id) =>
                            setDialogState(() => pickerStoreId = id),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      modalCtx.getRSize(20),
                      0,
                      modalCtx.getRSize(20),
                      modalCtx.getRSize(12),
                    ),
                    child: AppInput(
                      onChanged: (v) {
                        setDialogState(() {
                          searchQuery = v;
                        });
                      },
                      hintText: 'Search customers...',
                      prefixIcon: Icon(
                        AppIcons.search,
                        size: modalCtx.getRSize(18),
                        color: muted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<Customer>>(
                      valueListenable: ref.read(customerServiceProvider),
                      builder: (_, allCustomers, __) {
                        final customers = allCustomers.where((c) {
                          // Store filter
                          if (pickerStoreId != null &&
                              c.storeId != pickerStoreId) {
                            return false;
                          }
                          // Search filter
                          if (searchQuery.isEmpty) return true;
                          final q = searchQuery.toLowerCase();
                          return c.name.toLowerCase().contains(q) ||
                              (c.phone?.toLowerCase().contains(q) ?? false);
                        }).toList();
                        return ListView(
                          padding: EdgeInsets.fromLTRB(
                            modalCtx.getRSize(20),
                            0,
                            modalCtx.getRSize(20),
                            modalCtx.deviceBottomPadding +
                                modalCtx.getRSize(20),
                          ),
                          children: [
                            _buildCustomerTile(null, modalCtx),
                            ...customers.map(
                              (c) => _buildCustomerTile(c, modalCtx),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCustomerTile(Customer? customer, BuildContext modalCtx) {
    final bool isSelected = _activeCustomer?.id == customer?.id;
    final name = customer?.name ?? 'Walk-in Customer';
    final balanceKobo = customer == null
        ? 0
        : (ref.watch(creditBalancesKoboProvider).valueOrNull?[customer.id] ??
              0);
    final customerCreditBalance = balanceKobo / 100.0;
    final isOwe = customerCreditBalance < 0;
    final fixed =
        Theme.of(modalCtx).extension<AppFixedColors>() ?? AppFixedColors.light;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final base = AppDecorations.card(
      modalCtx,
      radius: AppSpacing.borderRadiusL,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: modalCtx.getRSize(8)),
      child: DecoratedBox(
        decoration: isSelected
            ? base.copyWith(border: Border.all(color: _primary, width: 1.5))
            : base,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('cart-picker-row-${customer?.id ?? 'walk-in'}'),
            onTap: () {
              setState(() {
                _activeCustomer = customer;
              });
              widget.onCustomerChanged(customer);
              ref.read(cartProvider).setActiveCustomer(customer);

              Navigator.pop(modalCtx);
            },
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.all(modalCtx.getRSize(12)),
                child: Row(
                  children: [
                    IconTile(
                      icon: customer == null
                          ? AppIcons.customerRole
                          : AppIcons.user,
                      tone: customer == null
                          ? IconTileTone.neutral
                          : IconTileTone.info,
                      size: 40,
                    ),
                    SizedBox(width: modalCtx.getRSize(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: modalCtx
                                .boldStyle(15)
                                .copyWith(color: _text),
                          ),
                          if (customer != null) ...[
                            SizedBox(height: modalCtx.getRSize(2)),
                            Text(
                              'Bal: ${formatCurrency(customerCreditBalance)}',
                              style: modalCtx
                                  .semiBoldStyle(12)
                                  .copyWith(
                                    color: isOwe ? fixed.danger : fixed.green,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (isSelected)
                      AppIcon(
                        AppIcons.checkCircle,
                        filled: true,
                        color: _primary,
                        size: modalCtx.getRSize(22),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editItem(BuildContext ctx, Map<String, dynamic> item) async {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final removed = await EditItemModal.show(ctx, item);
    if (removed != null && mounted) {
      // Offer a 5s Undo for the removed line (§13.2).
      AppNotification.showAction(
        context,
        'Item removed.',
        actionLabel: 'Undo',
        onAction: () => ref.read(cartProvider).restoreLine(removed),
      );
    }
  }

  /// A quantity as the cart shows it: "2", "1.5" (no trailing ".0").
  static String _qtyLabel(double qty) {
    if (qty == qty.roundToDouble()) return qty.toInt().toString();
    return qty.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  /// "−10%" / "−₦500" for a discounted cart line (§13.3).
  String _discountBadgeLabel(Map<String, dynamic> item) {
    final kind = item['discountKind'] as String?;
    final value = (item['discountValue'] as num?)?.toDouble() ?? 0.0;
    final valueText = value == value.toInt()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    return kind == 'naira'
        ? '−$activeCurrencySymbol$valueText'
        : '−$valueText%';
  }

  /// The tags under a line's "qty × price": "Custom price" when the unit
  /// price was hand-set (§13.4), then the line discount (§13.3).
  List<Widget> _lineBadges(Map<String, dynamic> item) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        _primary.withValues(alpha: 0.12);
    return [
      if (item['customPriceKobo'] != null)
        CartLineBadge(label: 'Custom price', color: _primary, fill: tint),
      if (((item['discountKobo'] as int?) ?? 0) > 0)
        CartLineBadge(
          label: _discountBadgeLabel(item),
          color: f.green,
          fill: f.greenTint,
        ),
    ];
  }

  /// The stepper's +: one more, clamped to the line's stock cap by
  /// `CartService.updateQty` exactly as the Edit Item sheet does.
  void _incrementLine(Map<String, dynamic> item) {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final qty = (item['qty'] as num).toDouble();
    final applied = ref
        .read(cartProvider)
        .updateQty(item['name'] as String, qty + 1);
    if (!applied && mounted) {
      final cap = ((item['maxStock'] as int?) ?? (1 << 30)).toDouble();
      AppNotification.showInfo(
        context,
        '${_qtyLabel(cap)} in stock — quantity can\'t exceed this',
      );
    }
  }

  /// The stepper's −: one fewer; at the last unit it is the red bin, which
  /// removes the line with the same 5s Undo as the Edit Item sheet (§13.2).
  void _decrementLine(Map<String, dynamic> item) {
    if (ref.read(zeroStoresEmptySurfaceProvider)) return;
    final qty = (item['qty'] as num).toDouble();
    final cart = ref.read(cartProvider);
    if (qty <= 1) {
      final removed = Map<String, dynamic>.from(item);
      cart.removeItem(item['name'] as String);
      AppNotification.showAction(
        context,
        'Item removed.',
        actionLabel: 'Undo',
        onAction: () => ref.read(cartProvider).restoreLine(removed),
      );
      return;
    }
    cart.updateQty(item['name'] as String, qty - 1);
  }

  /// Everything the cart's money display AND the checkout hand-off are computed
  /// from, derived in ONE place from [items].
  ///
  /// Extracted from `build` deliberately. These figures used to be locals in
  /// `build`, captured by the Checkout button's closure — so the page was handed
  /// whatever the last paint had computed. Deriving them on demand means the
  /// checkout quote is built from the cart as it stands when the button is
  /// actually pressed, and means the displayed deposit and the deposit sent to
  /// checkout cannot drift apart.
  _CartQuote _quote(List<Map<String, dynamic>> items, {required bool isCrate}) {
    final sub = items.fold<double>(
      0.0,
      (s, i) =>
          s +
          stockValue(
            (i['price'] as num).toDouble(),
            (i['qty'] as num).toDouble(),
          ),
    );

    // ── Bottle detection & crate deposit computation ──
    // Empty crates are tracked for any product whose unit == 'Bottle'.
    // The deposit per bottle comes off the line's `emptyCrateValueKobo`, which
    // CartCrateSync holds equal to the manufacturer's current
    // `depositAmountKobo` for as long as this screen is mounted — so an owner
    // editing a brand deposit reflects here without the cart being rebuilt.
    // CrateSizeGroups are no longer the gating identifier.
    // §13.4 / rule #13 — empty-crate features (the deposit section here + at
    // checkout, the crate breakdown, the customer crate-credit offset) only
    // exist for Bar / Beer Distributor businesses. A non-crate business can
    // still have a Bottle product with trackEmpties on (it's the default unit
    // and the product-creation toggle isn't business-gated), so gate on the
    // business type — the same check Inventory's Empty Crates tab uses. Gating
    // bottleItems at the source empties everything downstream (deposit lines,
    // crateLines passed to checkout, customer crate-credit) for non-crate types.
    final bottleItems = crateBearingLines(items, isCrate: isCrate);
    final hasBottles = bottleItems.isNotEmpty;

    // Crate-bearing lines whose crate value has never been configured. Each
    // line's value is kept equal to the brand's canonical `depositAmountKobo`
    // (ADR 0023 rule 2) by CartCrateSync, so 0 here means exactly one thing:
    // nobody has set what a crate of this brand is worth.
    final unconfiguredCrateItems = unconfiguredCrateValueProducts(bottleItems);

    // Compute aggregate deposit across items.
    // Required deposit = emptyCrateValueKobo × qty for each bottle item.
    double computedDeposit = 0;
    final List<_CrateDepositLine> depositLines = [];
    final Map<String, double> mfrAmounts = {};
    final Map<String, double> mfrQtys = {};
    final Map<String, String> mfrNames = {};
    // Tracks items with no manufacturerId, keyed by product name
    final Map<String, double> ungroupedAmounts = {};
    final Map<String, double> ungroupedQtys = {};

    for (final item in bottleItems) {
      final mfrId = item['manufacturerId'] as String?;
      final qty = (item['qty'] as num).toDouble();
      final int crateValueKobo = lineCrateValueKobo(item);

      final depositPerCrate = crateValueKobo / 100.0;
      final amount = qty * depositPerCrate;
      computedDeposit += amount;

      if (mfrId != null) {
        mfrQtys[mfrId] = (mfrQtys[mfrId] ?? 0) + qty;
        mfrAmounts[mfrId] = (mfrAmounts[mfrId] ?? 0) + amount;
        final mfr = _manufacturers.where((m) => m.id == mfrId).firstOrNull;
        mfrNames[mfrId] = mfr?.name ?? (item['name'] as String);
      } else {
        final label = item['name'] as String;
        ungroupedQtys[label] = (ungroupedQtys[label] ?? 0) + qty;
        ungroupedAmounts[label] = (ungroupedAmounts[label] ?? 0) + amount;
      }
    }

    final sortedMfrIds = mfrQtys.keys.toList()
      ..sort((a, b) => (mfrNames[a] ?? '').compareTo(mfrNames[b] ?? ''));

    // §13.4 Ring 3 — per-brand crate lines handed to checkout, where the
    // deposit is now captured (auto-filled rate × crates, editable/zeroable).
    // Only manufacturer-grouped bottle lines are passed: the deposit + crate
    // balance are keyed per manufacturer (createOrder skips items with no
    // manufacturerId), so ungrouped bottles can't be deposit-tracked.
    final crateLines = <Map<String, dynamic>>[];
    for (final mfrId in sortedMfrIds) {
      depositLines.add(
        _CrateDepositLine(
          label: mfrNames[mfrId]!,
          color: _cgColors[mfrId.hashCode.abs() % _cgColors.length],
          qty: mfrQtys[mfrId]!,
          amount: mfrAmounts[mfrId]!,
        ),
      );
      final mfr = _manufacturers.where((m) => m.id == mfrId).firstOrNull;
      crateLines.add({
        'manufacturerId': mfrId,
        'name': mfrNames[mfrId]!,
        'crates': mfrQtys[mfrId]!,
        'rateKobo': mfr?.depositAmountKobo ?? 0,
      });
    }

    for (final entry in ungroupedAmounts.entries) {
      depositLines.add(
        _CrateDepositLine(
          label: entry.key,
          color: Theme.of(context).colorScheme.primary,
          qty: ungroupedQtys[entry.key]!,
          amount: entry.value,
        ),
      );
    }

    // #202: a "customer crate credit" term used to be subtracted from the
    // payable here, read from `Customer.emptyCratesBalance` — a map hardcoded
    // `const {}` at every construction site, so the credit was always ₦0. It was
    // deleted rather than wired up: the crate balance sign convention is
    // positive = the customer OWES us empties, so completing it as written would
    // have handed checkout discounts to crate DEBTORS, keyed fragilely by
    // manufacturer *name* (CRATE_TRACKING_AUDIT.md §D). Reviving customer crate
    // credit needs a deliberate design AND its own printed receipt line — see
    // `ReceiptTotals.totalKobo`.

    // Per-line discounts (§13.3). Summed across the cart and subtracted from
    // the payable total. discountKobo lives on each line (set in the Edit
    // Quantity modal); converted to naira here to match `sub`.
    final discountTotal = items.fold<double>(
      0.0,
      (s, i) => s + (((i['discountKobo'] as int?) ?? 0) / 100.0),
    );

    // Goods total = Subtotal − Discounts. The crate deposit is no longer
    // entered here — it's captured (auto-filled per brand) at checkout and
    // added to the payable there (§13.4 Ring 3). computedDeposit stays
    // informational on the Empty Crates card below.
    final tot = sub - discountTotal;

    return _CartQuote(
      subtotal: sub,
      discountTotal: discountTotal,
      total: tot,
      computedDeposit: computedDeposit,
      depositLines: depositLines,
      crateLines: crateLines,
      hasBottles: hasBottles,
      unconfiguredCrateItems: unconfiguredCrateItems,
    );
  }

  /// The menu button before the header tile, under 600dp only (at 600dp+ the
  /// rail carries the menu).
  Widget? _leading(BuildContext context) => context.isRailLayout
      ? null
      : const SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: MenuButton(),
        );

  @override
  Widget build(BuildContext context) {
    final inPanel = widget.onClosePanel != null;
    if (ref.watch(zeroStoresEmptySurfaceProvider)) {
      return SharedScaffold(
        activeRoute: 'cart',
        backgroundColor: _bg,
        appBar: CartTopBar(
          height: cartTopBarHeight(context),
          subtitle: ref.watch(activeStoreLabelProvider),
          leading: _leading(context),
          bell: inPanel ? null : const NotificationBell(),
          onClose: widget.onClosePanel,
        ),
        body: const SafeArea(child: FirstRunEmptyState()),
      );
    }

    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // The lines show in the order they were added and never move when a
    // quantity changes (#385: sorting by quantity made a line jump to the top
    // mid-edit). The quote is still built from the quantity-sorted copy it
    // has always used, so every figure — including the order of its sums and
    // of the Empty Crates rows — is exactly as before; checkout keeps its own
    // sort in [_openCheckout].
    final cartItems = List<Map<String, dynamic>>.from(
      ref.read(cartProvider).value,
    );
    final quoteItems = List<Map<String, dynamic>>.from(cartItems)
      ..sort((a, b) => b['qty'].compareTo(a['qty']));
    final quote = _quote(
      quoteItems,
      isCrate: businessTracksCrates(ref.watch(currentBusinessProvider)),
    );
    final sub = quote.subtotal;
    final discountTotal = quote.discountTotal;
    final tot = quote.total;
    final computedDeposit = quote.computedDeposit;
    final depositLines = quote.depositLines;
    final hasBottles = quote.hasBottles;
    final unconfiguredCrateItems = quote.unconfiguredCrateItems;

    final customerName = _activeCustomer?.name ?? 'Walk-in Customer';
    final activeBalanceKobo = _activeCustomer == null
        ? 0
        : (ref
                  .watch(creditBalancesKoboProvider)
                  .valueOrNull?[_activeCustomer!.id] ??
              0);
    final customerCreditBalance = activeBalanceKobo / 100.0;
    final isOwe = customerCreditBalance < 0;
    final fixed =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

    final categoryNames = <String, String>{
      for (final c
          in ref.watch(allCategoriesProvider).valueOrNull ??
              const <CategoryData>[])
        c.id: c.name,
    };

    final itemCount = cartItems.length;
    final gutter = context.getRSize(16);
    final bottomPadding = context.deviceBottomPadding;

    Widget lineAt(int i) {
      final item = _isClearing ? _animatingItems[i] : cartItems[i];
      final qty = (item['qty'] as num?)?.toDouble() ?? 0.0;
      final price = (item['price'] as num?)?.toDouble() ?? 0.0;
      final gross = qty * price;
      final discountKobo = (item['discountKobo'] as int?) ?? 0;
      final net = gross - discountKobo / 100.0;
      final rawCategory = item['category']?.toString();
      final visual = categoryVisual(
        categoryNames[rawCategory] ?? rawCategory,
        fixed,
      );
      // "60cl · Bottle": the product's own subtitle, then its unit (as the
      // Request Stock tiles). The unit moved here from the front of the name.
      final detail = [
        item['subtitle'] as String?,
        item['unit'] as String?,
      ].where((s) => s != null && s.trim().isNotEmpty).join(' · ');
      final card = CartLine(
        key: cartLineKey(
          productId: item['id'] as String?,
          name: item['name'] as String,
        ),
        name: productDisplayName(
          item['name'] as String,
          item['size'] as String?,
        ),
        icon: visual.icon,
        tileTint: visual.tint,
        tileIconColor: visual.iconColor,
        quantityLabel: _qtyLabel(qty),
        unitPriceLabel: formatCurrency(price),
        totalLabel: formatCurrency(net),
        originalTotalLabel: discountKobo > 0 ? formatCurrency(gross) : null,
        badges: _lineBadges(item),
        detail: detail.isEmpty ? null : detail,
        isLastUnit: qty <= 1,
        onIncrement: _isClearing ? () {} : () => _incrementLine(item),
        onDecrement: _isClearing ? () {} : () => _decrementLine(item),
        onTap: _isClearing
            ? null
            : () {
                HapticFeedback.mediumImpact();
                _editItem(context, item);
              },
      );

      if (!_isClearing) return card;

      // Staggered slide-right + fade during clear
      return AnimatedBuilder(
        animation: _clearCtrl,
        builder: (_, child) {
          const staggerStep = 0.12;
          final delay = i * staggerStep;
          final t = ((_clearCtrl.value - delay) / (1.0 - delay)).clamp(
            0.0,
            1.0,
          );
          final curve = Curves.easeIn.transform(t);
          return Transform.translate(
            offset: Offset(curve * context.screenWidth, 0),
            child: Opacity(
              opacity: (1.0 - curve).clamp(0.0, 1.0),
              child: child,
            ),
          );
        },
        child: card,
      );
    }

    // Subtotal, then the crate cards and the discount, in the mockup's order.
    // Every condition is today's; only the look and position changed (#385).
    final summary = Padding(
      padding: EdgeInsets.fromLTRB(gutter, context.getRSize(4), gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CartSubtotalRow(label: 'Subtotal', value: formatCurrency(sub)),
          // Deliberately NOT behind the registered-customer gate below: a
          // missing crate value is a product-setup problem, and the cashier
          // who can see it is the one holding the item. It also has to appear
          // ABOVE the deposit figures so the ₦0 lines there are explained
          // rather than read as a real crate value.
          if (unconfiguredCrateItems.isNotEmpty) ...[
            SizedBox(height: context.getRSize(12)),
            CrateValueMissingCard(productNames: unconfiguredCrateItems),
          ],
          // §3.13 — the Empty Crates section is hidden for walk-in customers
          // (no profile = no crate balance/deposit to defer); it shows only
          // for a registered customer, matching checkout's _depositApplies
          // gate.
          if (hasBottles && _activeCustomer != null) ...[
            SizedBox(height: context.getRSize(12)),
            EmptyCratesCard(
              goingOutLabel:
                  '${_qtyLabel(depositLines.fold<double>(0, (s, l) => s + l.qty))} going out',
              rows: [
                for (final line in depositLines)
                  (
                    label: line.label,
                    color: line.color,
                    qtyLabel: _qtyLabel(line.qty),
                    amountLabel: formatCurrency(line.amount),
                  ),
              ],
              requiredDepositLabel: formatCurrency(computedDeposit),
            ),
          ],
          if (discountTotal > 0) ...[
            SizedBox(height: context.getRSize(12)),
            CartDiscountRow(amountLabel: '−${formatCurrency(discountTotal)}'),
          ],
          SizedBox(height: context.getRSize(16)),
        ],
      ),
    );

    CartFooter footer({required bool pinned}) => CartFooter(
      totalLabel: formatCurrency(tot),
      onSave: _saveCurrentCart,
      onRecall: _viewSavedCarts,
      onCheckout: _goToCheckout,
      bottomPadding: bottomPadding,
      pinned: pinned,
    );

    return SharedScaffold(
      activeRoute: 'cart',
      backgroundColor: _bg,
      appBar: CartTopBar(
        height: cartTopBarHeight(context),
        subtitle: '$itemCount item${itemCount == 1 ? '' : 's'}',
        leading: _leading(context),
        bell: inPanel ? null : const NotificationBell(),
        onClear: cartItems.isEmpty ? null : _clearWithAnimation,
        onClose: widget.onClosePanel,
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Fixed customer card: it is how a sale goes on a customer's
            // account, so it never scrolls away (#255).
            Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                context.getRSize(12),
                gutter,
                context.getRSize(4),
              ),
              child: CartCustomerCard(
                name: customerName,
                balanceLabel:
                    'Bal: ${formatCurrency(customerCreditBalance.abs())} ${customerCreditBalance == 0 ? "clear" : (isOwe ? "overdue" : "credit")}',
                balanceColor: isOwe ? fixed.danger : fixed.green,
                onChange: _showChangeCustomerModal,
              ),
            ),
            // ── The lines and totals. The footer is pinned under them when
            // the space can hold both; on a short screen (a phone sideways,
            // or the keyboard up) it scrolls at the end instead, so the lines
            // are never starved (PRD #239).
            Expanded(
              child: cartItems.isEmpty
                  ? EmptyCartMessage(onRecall: _viewSavedCarts)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final pinned =
                            constraints.maxHeight >= context.getRSize(440);
                        final scroll = CustomScrollView(
                          slivers: [
                            if (_showCartHint)
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  gutter,
                                  context.getRSize(8),
                                  gutter,
                                  0,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: CartEditHint(
                                    onDismiss: () {
                                      setState(() => _showCartHint = false);
                                      // Deliberate close retires the hint
                                      // immediately so it never reappears
                                      // (the display in initState already
                                      // counted the view via markShown).
                                      uiHintService.markDismissed(
                                        UiHintService.hintCartTapEdit,
                                      );
                                    },
                                  ),
                                ),
                              ),
                            SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: gutter,
                                vertical: context.getRSize(8),
                              ),
                              sliver: SliverList.separated(
                                itemCount: _isClearing
                                    ? _animatingItems.length
                                    : cartItems.length,
                                separatorBuilder: (_, _) =>
                                    SizedBox(height: context.getRSize(12)),
                                itemBuilder: (_, i) => lineAt(i),
                              ),
                            ),
                            SliverToBoxAdapter(child: summary),
                            if (!pinned)
                              SliverToBoxAdapter(child: footer(pinned: false)),
                          ],
                        );
                        if (!pinned) return scroll;
                        return Column(
                          children: [
                            Expanded(child: scroll),
                            footer(pinned: true),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One derivation of the cart's money, shared by the display and the checkout
/// hand-off so the two can never disagree. See [_CartScreenState._quote].
class _CartQuote {
  final double subtotal;
  final double discountTotal;

  /// Goods payable: subtotal − discounts. The crate deposit is NOT in here —
  /// it is captured per brand at checkout and added to the payable there
  /// (§13.4 Ring 3).
  final double total;

  /// The full deposit the empties in this cart are worth, shown on the Empty
  /// Crates card. Informational — checkout captures what was actually paid.
  final double computedDeposit;
  final List<_CrateDepositLine> depositLines;

  /// Per-brand crate lines handed to checkout.
  final List<Map<String, dynamic>> crateLines;
  final bool hasBottles;

  /// Names of crate-tracked lines with no crate value configured. Drives
  /// [_CrateValueMissingBanner].
  final List<String> unconfiguredCrateItems;

  const _CartQuote({
    required this.subtotal,
    required this.discountTotal,
    required this.total,
    required this.computedDeposit,
    required this.depositLines,
    required this.crateLines,
    required this.hasBottles,
    required this.unconfiguredCrateItems,
  });
}

class _CrateDepositLine {
  final String label;
  final Color color;
  final double qty;
  final double amount;

  const _CrateDepositLine({
    required this.label,
    required this.color,
    required this.qty,
    required this.amount,
  });
}
