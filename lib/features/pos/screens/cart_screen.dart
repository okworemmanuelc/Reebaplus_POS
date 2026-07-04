import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';
import 'package:reebaplus_pos/shared/services/ui_hint_service.dart';
import 'package:flutter/services.dart';

class CartScreen extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> cart;
  final Customer? activeCustomer;
  final Function(Customer?) onCustomerChanged;
  final VoidCallback? onCheckoutSuccess;

  const CartScreen({
    super.key,
    required this.cart,
    this.activeCustomer,
    required this.onCustomerChanged,
    this.onCheckoutSuccess,
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

  Future<void> _saveCurrentCart() async {
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
        return Container(
          height: MediaQuery.of(context).size.height * 0.7,
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.all(modalCtx.getRSize(20)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Saved Carts',
                      style: TextStyle(
                        fontSize: modalCtx.getRFontSize(18),
                        fontWeight: FontWeight.w800,
                        color: _text,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(modalCtx),
                      icon: Icon(Icons.close, color: _subtext),
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
                        child: Text(
                          'No saved carts found',
                          style: TextStyle(color: _subtext),
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: modalCtx.deviceBottomPadding,
                      ),
                      itemCount: carts.length,
                      itemBuilder: (context, index) {
                        final cart = carts[index];
                        // ListTile paints its ink/background on the nearest
                        // Material; the modal's surface-colored Container sits
                        // above it and would hide those. A transparent Material
                        // gives the tile an ink target above that fill.
                        return Material(
                          type: MaterialType.transparency,
                          child: ListTile(
                          title: Text(
                            cart.name,
                            style: TextStyle(color: _text),
                          ),
                          subtitle: Text(
                            'Saved on ${cart.createdAt.toString().split('.')[0]}',
                            style: TextStyle(color: _subtext),
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () async {
                              try {
                                await db.ordersDao.deleteSavedCart(cart.id);
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
                          onTap: () async {
                            try {
                              final items = (jsonDecode(cart.cartData) as List)
                                  .cast<Map<String, dynamic>>();
                              Customer? customer;
                              if (cart.customerId != null) {
                                customer = custSvc.getById(cart.customerId!);
                              }
                              cartSvc.loadCart(
                                items,
                                customer,
                                storeId: cart.storeId,
                              );
                              Navigator.pop(modalCtx);
                              AppNotification.showSuccess(
                                context,
                                'Cart loaded',
                              );
                            } catch (e, st) {
                              CrashReporter.record(
                                e,
                                st,
                                context: 'pos.cart.load_saved',
                              );
                              if (!mounted) return;
                              Navigator.pop(modalCtx);
                              AppNotification.showError(
                                this.context,
                                'Could not load this saved cart.',
                              );
                            }
                          },
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

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _success =>
      Theme.of(context).extension<AppSemanticColors>()?.success ?? success;

  void _showChangeCustomerModal() {
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
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (modalCtx) {
        String searchQuery = '';
        String? pickerStoreId = defaultPickerStoreId;
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return SizedBox(
              height: MediaQuery.of(modalCtx).size.height * 0.85,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      modalCtx.getRSize(20),
                      modalCtx.getRSize(14),
                      modalCtx.getRSize(20),
                      0,
                    ),
                    child: Center(
                      child: Container(
                        width: modalCtx.getRSize(40),
                        height: modalCtx.getRSize(4),
                        decoration: BoxDecoration(
                          color: _border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: modalCtx.getRSize(16)),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: modalCtx.getRSize(20),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Select Customer',
                          style: TextStyle(
                            fontSize: modalCtx.getRFontSize(18),
                            fontWeight: FontWeight.w800,
                            color: _text,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Creating a customer needs `customers.add`
                            // (hard rule #6/#7) — hide "New" otherwise.
                            // The AddCustomerSheet save handler re-checks
                            // the same key at the write boundary.
                            if (Gates.addCustomer.allows(ref)) ...[
                              AppButton(
                                text: 'New',
                                variant: AppButtonVariant.secondary,
                                isFullWidth: false,
                                height: modalCtx.getRSize(36),
                                icon: FontAwesomeIcons.userPlus.data,
                                onPressed: () {
                                  Navigator.pop(modalCtx);
                                  AddCustomerSheet.show(
                                    context,
                                    onCustomerAdded: (newCustomer) {
                                      setState(
                                        () => _activeCustomer = newCustomer,
                                      );
                                      widget.onCustomerChanged(newCustomer);
                                      ref
                                          .read(cartProvider)
                                          .setActiveCustomer(newCustomer);
                                    },
                                  );
                                },
                              ),
                              SizedBox(width: modalCtx.getRSize(8)),
                            ],
                            IconButton(
                              onPressed: () => Navigator.pop(modalCtx),
                              icon: Icon(Icons.close, color: _subtext),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // ── Store filter ──
                  if (_stores.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        modalCtx.getRSize(20),
                        modalCtx.getRSize(4),
                        modalCtx.getRSize(20),
                        0,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            FontAwesomeIcons.store.data,
                            size: modalCtx.getRSize(12),
                            color: _subtext,
                          ),
                          SizedBox(width: modalCtx.getRSize(6)),
                          Expanded(
                            child: AppDropdown<String?>(
                              value: pickerStoreId,
                              items: [
                                DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text(
                                    'All Stores',
                                    style: TextStyle(
                                      fontSize: modalCtx.getRFontSize(13),
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                                ..._stores.map(
                                  (w) => DropdownMenuItem<String?>(
                                    value: w.id,
                                    child: Text(
                                      w.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: modalCtx.getRFontSize(13),
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: (id) =>
                                  setDialogState(() => pickerStoreId = id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: modalCtx.getRSize(20),
                      vertical: modalCtx.getRSize(8),
                    ),
                    child: AppInput(
                      onChanged: (v) {
                        setDialogState(() {
                          searchQuery = v;
                        });
                      },
                      hintText: 'Search customers...',
                      prefixIcon: Icon(
                        FontAwesomeIcons.magnifyingGlass.data,
                        size: modalCtx.getRSize(16),
                        color: _subtext,
                      ),
                      fillColor: Theme.of(context).cardColor,
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
                            modalCtx.deviceBottomPadding + 20,
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

    return InkWell(
      onTap: () {
        setState(() {
          _activeCustomer = customer;
        });
        widget.onCustomerChanged(customer);
        ref.read(cartProvider).setActiveCustomer(customer);

        Navigator.pop(modalCtx);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.symmetric(
          vertical: modalCtx.getRSize(12),
          horizontal: modalCtx.getRSize(8),
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: _border.withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(modalCtx.getRSize(10)),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                customer == null
                    ? FontAwesomeIcons.userTag.data
                    : FontAwesomeIcons.user.data,
                size: modalCtx.getRSize(16),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            SizedBox(width: modalCtx.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: modalCtx.getRFontSize(15),
                      color: _text,
                    ),
                  ),
                  if (customer != null) ...[
                    SizedBox(height: modalCtx.getRSize(4)),
                    Row(
                      children: [
                        Icon(
                          FontAwesomeIcons.nairaSign.data,
                          size: modalCtx.getRSize(10),
                          color: customerCreditBalance == 0
                              ? success
                              : (isOwe ? danger : success),
                        ),
                        Text(
                          ' Bal: ${formatCurrency(customerCreditBalance)}',
                          style: TextStyle(
                            fontSize: modalCtx.getRFontSize(12),
                            color: customerCreditBalance == 0
                                ? success
                                : (isOwe ? danger : success),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (isSelected)
              Icon(
                FontAwesomeIcons.circleCheck.data,
                color: Theme.of(context).colorScheme.primary,
                size: modalCtx.getRSize(18),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editItem(BuildContext ctx, Map<String, dynamic> item) async {
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

  /// Small "−10%" / "−₦500" badge on a discounted cart line (§13.3).
  Widget _discountBadge(Map<String, dynamic> item) {
    final kind = item['discountKind'] as String?;
    final value = (item['discountValue'] as num?)?.toDouble() ?? 0.0;
    final valueText = value == value.toInt()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    final label = kind == 'naira'
        ? '−$activeCurrencySymbol$valueText'
        : '−$valueText%';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(2),
      ),
      decoration: BoxDecoration(
        color: _success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          fontWeight: FontWeight.w800,
          color: _success,
        ),
      ),
    );
  }

  /// Small "Custom price" badge on a cart line whose unit price was hand-set
  /// (§13.4), so it's clear the line isn't at its designated selling price.
  Widget _customPriceBadge() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(2),
      ),
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Custom price',
        style: TextStyle(
          fontSize: context.getRFontSize(11),
          fontWeight: FontWeight.w800,
          color: _primary,
        ),
      ),
    );
  }

  Widget _totalRow(
    String label,
    double value, {
    bool small = false,
    bool large = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.getRFontSize(large ? 18 : 14),
            fontWeight: large ? FontWeight.bold : FontWeight.w600,
            color: large ? _text : _subtext,
          ),
        ),
        Text(
          formatCurrency(value),
          style: TextStyle(
            fontSize: context.getRFontSize(large ? 22 : 15),
            fontWeight: FontWeight.w800,
            color: large ? _primary : _text,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    final cartItems = List<Map<String, dynamic>>.from(
      ref.read(cartProvider).value,
    );
    cartItems.sort((a, b) => b['qty'].compareTo(a['qty']));
    final sub = cartItems.fold<double>(
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
    // The deposit price per bottle is read live from the manufacturer's
    // current `depositAmountKobo`, so a CEO edit reflects everywhere
    // immediately. CrateSizeGroups are no longer the gating identifier.
    // §13.4 / rule #13 — empty-crate features (the deposit section here + at
    // checkout, the crate breakdown, the customer crate-credit offset) only
    // exist for Bar / Beer Distributor businesses. A non-crate business can
    // still have a Bottle product with trackEmpties on (it's the default unit
    // and the product-creation toggle isn't business-gated), so gate on the
    // business type — the same check Inventory's Empty Crates tab uses. Gating
    // bottleItems at the source empties everything downstream (deposit lines,
    // crateLines passed to checkout, customer crate-credit) for non-crate types.
    final isCrate = businessTracksCrates(ref.watch(currentBusinessProvider));
    final bottleItems = !isCrate
        ? const <Map<String, dynamic>>[]
        : cartItems
              .where(
                (i) =>
                    (i['unit'] as String?)?.toLowerCase() == 'bottle' &&
                    (i['trackEmpties'] as bool? ?? false),
              )
              .toList();
    final hasBottles = bottleItems.isNotEmpty;

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
      final int crateValueKobo = (item['emptyCrateValueKobo'] as int?) ?? 0;

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

    // Customer crate balance offset — sum credits per manufacturer using
    // the customer's stored balance (keyed by manufacturer name for now).
    double customerCrateCredit = 0;
    if (hasBottles && _activeCustomer != null) {
      for (final mfrId in mfrQtys.keys) {
        final mfrName = mfrNames[mfrId] ?? '';
        final bal = _activeCustomer!.emptyCratesBalance[mfrName] ?? 0;
        if (bal <= 0) continue;
        // Use the per-manufacturer deposit amount for credit calculation
        final mfr = _manufacturers.where((m) => m.id == mfrId).firstOrNull;
        final depositKobo = mfr?.depositAmountKobo ?? 0;
        if (depositKobo <= 0) continue;
        customerCrateCredit += bal * (depositKobo / 100.0);
      }
    }

    // Per-line discounts (§13.3). Summed across the cart and subtracted from
    // the payable total. discountKobo lives on each line (set in the Edit
    // Quantity modal); converted to naira here to match `sub`.
    final discountTotal = cartItems.fold<double>(
      0.0,
      (s, i) => s + (((i['discountKobo'] as int?) ?? 0) / 100.0),
    );

    // Goods total = Subtotal − Discounts − Credit. The crate deposit is no
    // longer entered here — it's captured (auto-filled per brand) at checkout
    // and added to the payable there (§13.4 Ring 3). computedDeposit stays
    // informational on the Empty Crates card below.
    final tot = sub - discountTotal - customerCrateCredit;

    final customerName = _activeCustomer?.name ?? 'Walk-in Customer';
    final activeBalanceKobo = _activeCustomer == null
        ? 0
        : (ref
                  .watch(creditBalancesKoboProvider)
                  .valueOrNull?[_activeCustomer!.id] ??
              0);
    final customerCreditBalance = activeBalanceKobo / 100.0;
    final isOwe = customerCreditBalance < 0;

    return SharedScaffold(
      activeRoute: 'cart',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: context.isDesktop ? null : const MenuButton(),
        title: AppBarHeader(
          icon: FontAwesomeIcons.cartShopping.data,
          title: 'Cart',
          subtitle: ref.watch(activeStoreLabelProvider),
        ),
        actions: [
          const NotificationBell(),
          if (cartItems.isNotEmpty)
            GestureDetector(
              onTap: _clearWithAnimation,
              child: Container(
                margin: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(10),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(4),
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.trashCan.data,
                      color: Theme.of(context).colorScheme.error,
                      size: context.getRSize(13),
                    ),
                    SizedBox(width: context.getRSize(6)),
                    Text(
                      'Clear',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Fixed customer tab — full device width ──
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                context.getRSize(8),
                context.getRSize(20),
                context.getRSize(8),
              ),
              decoration: BoxDecoration(
                color: _surface,
                border: Border(bottom: BorderSide(color: _border)),
              ),
              child: Container(
                padding: EdgeInsets.all(context.getRSize(16)),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(context.getRSize(10)),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        _activeCustomer == null
                            ? FontAwesomeIcons.userTag.data
                            : FontAwesomeIcons.user.data,
                        size: context.getRSize(16),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    SizedBox(width: context.getRSize(14)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            customerName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: context.getRFontSize(14),
                              color: _text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Row(
                            children: [
                              Icon(
                                FontAwesomeIcons.nairaSign.data,
                                size: context.getRSize(11),
                                color: customerCreditBalance == 0
                                    ? success
                                    : (isOwe ? danger : success),
                              ),
                              Flexible(
                                child: Text(
                                  ' Bal: $activeCurrencySymbol${customerCreditBalance.abs().toStringAsFixed(0)} ${customerCreditBalance == 0 ? "clear" : (isOwe ? "overdue" : "credit")}',
                                  style: TextStyle(
                                    fontSize: context.getRFontSize(12),
                                    color: customerCreditBalance == 0
                                        ? success
                                        : (isOwe ? danger : success),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    GestureDetector(
                      onTap: () => _showChangeCustomerModal(),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(12),
                          vertical: context.getRSize(6),
                        ),
                        decoration: BoxDecoration(
                          color: _bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _border),
                        ),
                        child: Text(
                          'Change',
                          style: TextStyle(
                            fontSize: context.getRFontSize(12),
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // ── Scrollable content: cart items + totals ──
            Expanded(
              child: cartItems.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            FontAwesomeIcons.cartArrowDown.data,
                            size: context.getRSize(48),
                            color: _border,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          Text(
                            'Cart is empty',
                            style: TextStyle(
                              color: _subtext,
                              fontWeight: FontWeight.bold,
                              fontSize: context.getRFontSize(16),
                            ),
                          ),
                          SizedBox(height: context.getRSize(20)),
                          // Recall stays reachable with an empty cart so a
                          // saved cart can be restored before adding items.
                          AppButton(
                            text: 'Recall',
                            variant: AppButtonVariant.outline,
                            icon: FontAwesomeIcons.clockRotateLeft.data,
                            isFullWidth: false,
                            onPressed: _viewSavedCarts,
                          ),
                        ],
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        if (_showCartHint)
                          SliverToBoxAdapter(
                            child: Container(
                              margin: EdgeInsets.fromLTRB(
                                context.getRSize(20),
                                context.getRSize(8),
                                context.getRSize(20),
                                0,
                              ),
                              padding: EdgeInsets.all(context.getRSize(12)),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    FontAwesomeIcons.circleInfo.data,
                                    size: context.getRSize(16),
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                  SizedBox(width: context.getRSize(12)),
                                  Expanded(
                                    child: Text(
                                      'Tap an item to edit quantity, price or discount.',
                                      style: TextStyle(
                                        fontSize: context.getRFontSize(13),
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      FontAwesomeIcons.xmark.data,
                                      size: context.getRSize(16),
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                    onPressed: () {
                                      setState(() => _showCartHint = false);
                                      uiHintService.markShown(
                                        UiHintService.hintCartTapEdit,
                                      );
                                    },
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: EdgeInsets.symmetric(
                              horizontal: context.getRSize(20),
                              vertical: context.getRSize(8),
                            ),
                            itemCount: _isClearing
                                ? _animatingItems.length
                                : cartItems.length,
                            separatorBuilder: (_, idx) =>
                                SizedBox(height: context.getRSize(12)),
                            itemBuilder: (_, i) {
                              final item = _isClearing
                                  ? _animatingItems[i]
                                  : cartItems[i];
                              final rawColor = item['color'];
                              final Color c = rawColor is Color
                                  ? rawColor
                                  : rawColor is String
                                  ? Color(
                                      int.parse(
                                        rawColor.replaceFirst('#', '0xFF'),
                                      ),
                                    )
                                  : Theme.of(context).colorScheme.primary;
                              // Build card once, reused in both paths
                              final card = InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: _isClearing
                                    ? null
                                    : () {
                                        HapticFeedback.mediumImpact();
                                        _editItem(context, item);
                                      },
                                child: Container(
                                  padding: EdgeInsets.all(context.getRSize(12)),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).cardColor,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: _border.withValues(alpha: 0.5),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: context.getRSize(48),
                                        height: context.getRSize(48),
                                        decoration: BoxDecoration(
                                          color: c.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          item['icon'] == null
                                              ? FontAwesomeIcons.box.data
                                              : item['icon'] is IconData
                                              ? item['icon'] as IconData
                                              : item['icon'] is int
                                              ? productIconFromCodePoint(
                                                  item['icon'] as int,
                                                )
                                              : FontAwesomeIcons.box.data,
                                          color: c,
                                          size: context.getRSize(22),
                                        ),
                                      ),
                                      SizedBox(width: context.getRSize(14)),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              productDisplayName(
                                                item['name'] as String,
                                                item['size'] as String?,
                                                unit: item['unit'] as String?,
                                              ),
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: context.getRFontSize(
                                                  15,
                                                ),
                                                color: _text,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            SizedBox(
                                              height: context.getRSize(4),
                                            ),
                                            Text(
                                              '${((item['qty'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(1)} × ${formatCurrency(((item['price'] as num?)?.toDouble() ?? 0.0))}',
                                              style: TextStyle(
                                                fontSize: context.getRFontSize(
                                                  13,
                                                ),
                                                fontWeight: FontWeight.w600,
                                                color: _subtext,
                                              ),
                                            ),
                                            if (item['customPriceKobo'] !=
                                                null) ...[
                                              SizedBox(
                                                height: context.getRSize(4),
                                              ),
                                              _customPriceBadge(),
                                            ],
                                            if (((item['discountKobo']
                                                        as int?) ??
                                                    0) >
                                                0) ...[
                                              SizedBox(
                                                height: context.getRSize(4),
                                              ),
                                              _discountBadge(item),
                                            ],
                                          ],
                                        ),
                                      ),
                                      Builder(
                                        builder: (context) {
                                          final gross =
                                              ((item['qty'] as num?)
                                                      ?.toDouble() ??
                                                  0.0) *
                                              ((item['price'] as num?)
                                                      ?.toDouble() ??
                                                  0.0);
                                          final discountKobo =
                                              (item['discountKobo'] as int?) ??
                                              0;
                                          final net =
                                              gross - discountKobo / 100.0;
                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              if (discountKobo > 0)
                                                Text(
                                                  formatCurrency(gross),
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: context
                                                        .getRFontSize(12),
                                                    color: _subtext,
                                                    decoration: TextDecoration
                                                        .lineThrough,
                                                  ),
                                                ),
                                              FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  formatCurrency(net),
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: context
                                                        .getRFontSize(16),
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );

                              if (!_isClearing) return card;

                              // Staggered slide-right + fade during clear
                              return AnimatedBuilder(
                                animation: _clearCtrl,
                                builder: (_, child) {
                                  const staggerStep = 0.12;
                                  final delay = i * staggerStep;
                                  final t =
                                      ((_clearCtrl.value - delay) /
                                              (1.0 - delay))
                                          .clamp(0.0, 1.0);
                                  final curve = Curves.easeIn.transform(t);
                                  return Transform.translate(
                                    offset: Offset(
                                      curve * MediaQuery.of(context).size.width,
                                      0,
                                    ),
                                    child: Opacity(
                                      opacity: (1.0 - curve).clamp(0.0, 1.0),
                                      child: child,
                                    ),
                                  );
                                },
                                child: card,
                              );
                            },
                          ),
                        ),
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // ── Totals section ──
                              Container(
                                padding: EdgeInsets.fromLTRB(
                                  context.getRSize(20),
                                  context.getRSize(20),
                                  context.getRSize(20),
                                  context.getRSize(100),
                                ),
                                decoration: BoxDecoration(
                                  color: _surface,
                                  border: Border(
                                    top: BorderSide(color: _border),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    _totalRow('Subtotal', sub, small: true),
                                    if (discountTotal > 0) ...[
                                      SizedBox(height: context.getRSize(6)),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            'Saved',
                                            style: TextStyle(
                                              fontSize: context.getRFontSize(
                                                14,
                                              ),
                                              fontWeight: FontWeight.w600,
                                              color: _success,
                                            ),
                                          ),
                                          Text(
                                            '−${formatCurrency(discountTotal)}',
                                            style: TextStyle(
                                              fontSize: context.getRFontSize(
                                                15,
                                              ),
                                              fontWeight: FontWeight.w800,
                                              color: _success,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    SizedBox(height: context.getRSize(8)),
                                    // §3.13 — the Empty Crates section is
                                    // hidden for walk-in customers (no profile
                                    // = no crate balance/deposit to defer); it
                                    // shows only for a registered customer,
                                    // matching checkout's _depositApplies gate.
                                    if (hasBottles &&
                                        _activeCustomer != null) ...[
                                      // ── Empty Crates section ──
                                      Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.all(
                                          context.getRSize(14),
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).cardColor,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(color: _border),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: EdgeInsets.all(
                                                    context.getRSize(8),
                                                  ),
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      colors: [
                                                        Theme.of(
                                                          context,
                                                        ).colorScheme.secondary,
                                                        Theme.of(
                                                          context,
                                                        ).colorScheme.primary,
                                                      ],
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Icon(
                                                    FontAwesomeIcons
                                                        .beerMugEmpty
                                                        .data,
                                                    size: context.getRSize(14),
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onPrimary,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: context.getRSize(10),
                                                ),
                                                Text(
                                                  'Empty Crates',
                                                  style: TextStyle(
                                                    fontSize: context
                                                        .getRFontSize(14),
                                                    fontWeight: FontWeight.w800,
                                                    color: _text,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            SizedBox(
                                              height: context.getRSize(12),
                                            ),
                                            ...depositLines.map(
                                              (line) => Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: context.getRSize(8),
                                                ),
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Expanded(
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            width: context
                                                                .getRSize(8),
                                                            height: context
                                                                .getRSize(8),
                                                            decoration:
                                                                BoxDecoration(
                                                                  color: line
                                                                      .color,
                                                                  shape: BoxShape
                                                                      .circle,
                                                                ),
                                                          ),
                                                          SizedBox(
                                                            width: context
                                                                .getRSize(8),
                                                          ),
                                                          Flexible(
                                                            child: Text(
                                                              '${line.label}  ×${line.qty.toStringAsFixed(1)}',
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                fontSize: context
                                                                    .getRFontSize(
                                                                      13,
                                                                    ),
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                color: _subtext,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    Text(
                                                      formatCurrency(
                                                        line.amount,
                                                      ),
                                                      style: TextStyle(
                                                        fontSize: context
                                                            .getRFontSize(13),
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: _text,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            Container(
                                              height: 1,
                                              color: _border,
                                            ),
                                            SizedBox(
                                              height: context.getRSize(8),
                                            ),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  'Required Deposit',
                                                  style: TextStyle(
                                                    fontSize: context
                                                        .getRFontSize(13),
                                                    fontWeight: FontWeight.bold,
                                                    color: _text,
                                                  ),
                                                ),
                                                Text(
                                                  formatCurrency(
                                                    computedDeposit,
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: context
                                                        .getRFontSize(14),
                                                    fontWeight: FontWeight.w800,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (customerCrateCredit > 0) ...[
                                              SizedBox(
                                                height: context.getRSize(6),
                                              ),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  Text(
                                                    'Deposit Paid',
                                                    style: TextStyle(
                                                      fontSize: context
                                                          .getRFontSize(12),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: success,
                                                    ),
                                                  ),
                                                  Text(
                                                    formatCurrency(
                                                      -customerCrateCredit,
                                                    ),
                                                    style: TextStyle(
                                                      fontSize: context
                                                          .getRFontSize(12),
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: success,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      SizedBox(height: context.getRSize(8)),
                                    ],
                                    SizedBox(height: context.getRSize(16)),
                                    Container(height: 1, color: _border),
                                    SizedBox(height: context.getRSize(16)),
                                    _totalRow('Total', tot, large: true),
                                    SizedBox(height: context.getRSize(16)),
                                    // ── Save/Recall Cart ──
                                    Row(
                                      children: [
                                        Expanded(
                                          child: AppButton(
                                            text: 'Save Cart',
                                            variant: AppButtonVariant.outline,
                                            icon: FontAwesomeIcons
                                                .floppyDisk
                                                .data,
                                            onPressed: _saveCurrentCart,
                                          ),
                                        ),
                                        SizedBox(width: context.getRSize(12)),
                                        Expanded(
                                          child: AppButton(
                                            text: 'Recall',
                                            variant: AppButtonVariant.outline,
                                            icon: FontAwesomeIcons
                                                .clockRotateLeft
                                                .data,
                                            onPressed: _viewSavedCarts,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: context.getRSize(16)),
                                    // ── Proceed to Checkout ──
                                    AppButton(
                                      text: 'Proceed to Checkout',
                                      variant: AppButtonVariant.primary,
                                      icon: FontAwesomeIcons.checkToSlot.data,
                                      onPressed: () {
                                        final currentCustomer = _activeCustomer;
                                        void goToCheckout() {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => CheckoutPage(
                                                cart:
                                                    List<
                                                      Map<String, dynamic>
                                                    >.from(cartItems),
                                                subtotal: sub,
                                                crateLines: crateLines,
                                                total: tot,
                                                customer: currentCustomer,
                                                onCheckoutSuccess:
                                                    widget.onCheckoutSuccess,
                                              ),
                                            ),
                                          );
                                        }

                                        goToCheckout();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
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
