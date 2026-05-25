import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
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

class CartScreen extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> cart;
  final double crateDeposit;
  final Customer? activeCustomer;
  final Function(Customer?) onCustomerChanged;
  final VoidCallback? onCheckoutSuccess;

  const CartScreen({
    super.key,
    required this.cart,
    required this.crateDeposit,
    this.activeCustomer,
    required this.onCustomerChanged,
    this.onCheckoutSuccess,
  });

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen>
    with SingleTickerProviderStateMixin {
  late double _crateDeposit;
  Customer? _activeCustomer;
  List<ManufacturerData> _manufacturers = [];
  List<WarehouseData> _warehouses = [];
  late final CartService _cart;

  // ── Clear animation ──
  late AnimationController _clearCtrl;
  bool _isClearing = false;
  List<Map<String, dynamic>> _animatingItems = [];

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
    _crateDeposit = 0;
    _activeCustomer = widget.activeCustomer;
    _clearCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _cart = ref.read(cartProvider);
    final db = ref.read(databaseProvider);
    _cart.addListener(_onCartChanged);
    _cart.activeCustomer.addListener(_onActiveCustomerChanged);
    db.select(db.warehouses).get().then((ws) {
      if (mounted) setState(() => _warehouses = ws);
    });
    db.select(db.manufacturers).watch().listen((data) {
      if (mounted) setState(() => _manufacturers = data);
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
      await ref
          .read(databaseProvider)
          .ordersDao
          .saveCart(
            SavedCartsCompanion.insert(
              name: name,
              customerId: drift.Value(_activeCustomer?.id),
              cartData: cartJson,
              createdAt: drift.Value(DateTime.now()),
              businessId: ref.read(authProvider).currentUser?.businessId ?? '',
            ),
          );

      if (mounted) {
        if (mounted) {
          AppNotification.showSuccess(context, 'Cart saved successfully');
        }
      }
    }
  }

  void _viewSavedCarts() {
    final db = ref.read(databaseProvider);
    final custSvc = ref.read(customerServiceProvider);
    final cartSvc = ref.read(cartProvider);
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
                  stream: db.ordersDao.watchSavedCarts(),
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
                      itemCount: carts.length,
                      itemBuilder: (context, index) {
                        final cart = carts[index];
                        return ListTile(
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
                              await db.ordersDao.deleteSavedCart(cart.id);
                            },
                          ),
                          onTap: () async {
                            final items = (jsonDecode(cart.cartData) as List)
                                .cast<Map<String, dynamic>>();
                            Customer? customer;
                            if (cart.customerId != null) {
                              customer = custSvc.getById(cart.customerId!);
                            }
                            cartSvc.loadCart(items, customer);
                            Navigator.pop(modalCtx);
                            AppNotification.showSuccess(context, 'Cart loaded');
                          },
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

  void _showChangeCustomerModal() {
    // Default picker warehouse — lone owner picks from POS lock.
    final String? defaultPickerWarehouseId = ref
        .read(navigationProvider)
        .lockedWarehouseId
        .value;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        String searchQuery = '';
        String? pickerWarehouseId = defaultPickerWarehouseId;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(modalCtx),
          child: DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            snap: true,
            snapSizes: const [0.5, 0.9],
            builder: (context, scrollController) {
              return StatefulBuilder(
                builder: (dialogCtx, setDialogState) {
                  return GestureDetector(
                    onTap: () {}, // Prevent tap from reaching the barrier
                    child: Container(
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
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
                                    AppButton(
                                      text: 'New',
                                      variant: AppButtonVariant.secondary,
                                      isFullWidth: false,
                                      height: modalCtx.getRSize(36),
                                      icon: FontAwesomeIcons.userPlus,
                                      onPressed: () {
                                        Navigator.pop(modalCtx);
                                        AddCustomerSheet.show(
                                          context,
                                          onCustomerAdded: (newCustomer) {
                                            setState(
                                              () =>
                                                  _activeCustomer = newCustomer,
                                            );
                                            widget.onCustomerChanged(
                                              newCustomer,
                                            );
                                            ref
                                                .read(cartProvider)
                                                .setActiveCustomer(newCustomer);
                                          },
                                        );
                                      },
                                    ),
                                    SizedBox(width: modalCtx.getRSize(8)),
                                    IconButton(
                                      onPressed: () => Navigator.pop(modalCtx),
                                      icon: Icon(Icons.close, color: _subtext),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // ── Warehouse filter ──
                          if (_warehouses.isNotEmpty)
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
                                    FontAwesomeIcons.warehouse,
                                    size: modalCtx.getRSize(12),
                                    color: _subtext,
                                  ),
                                  SizedBox(width: modalCtx.getRSize(6)),
                                  Expanded(
                                    child: AppDropdown<String?>(
                                      value: pickerWarehouseId,
                                      items: [
                                        DropdownMenuItem<String?>(
                                          value: null,
                                          child: Text(
                                            'All Warehouses',
                                            style: TextStyle(
                                              fontSize: modalCtx.getRFontSize(
                                                13,
                                              ),
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                            ),
                                          ),
                                        ),
                                        ..._warehouses.map(
                                          (w) => DropdownMenuItem<String?>(
                                            value: w.id,
                                            child: Text(
                                              w.name,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: modalCtx.getRFontSize(
                                                  13,
                                                ),
                                                fontWeight: FontWeight.w600,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                      onChanged: (id) => setDialogState(
                                        () => pickerWarehouseId = id,
                                      ),
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
                                FontAwesomeIcons.magnifyingGlass,
                                size: modalCtx.getRSize(16),
                                color: _subtext,
                              ),
                              fillColor: Theme.of(context).cardColor,
                            ),
                          ),
                          Expanded(
                            child: ValueListenableBuilder<List<Customer>>(
                              valueListenable: ref.read(
                                customerServiceProvider,
                              ),
                              builder: (_, allCustomers, __) {
                                final customers = allCustomers.where((c) {
                                  // Warehouse filter
                                  if (pickerWarehouseId != null &&
                                      c.warehouseId != pickerWarehouseId) {
                                    return false;
                                  }
                                  // Search filter
                                  if (searchQuery.isEmpty) return true;
                                  final q = searchQuery.toLowerCase();
                                  return c.name.toLowerCase().contains(q) ||
                                      (c.phone?.toLowerCase().contains(q) ??
                                          false);
                                }).toList();
                                return ListView(
                                  controller: scrollController,
                                  padding: EdgeInsets.fromLTRB(
                                    modalCtx.getRSize(20),
                                    0,
                                    modalCtx.getRSize(20),
                                    modalCtx.bottomInset + 20,
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
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildCustomerTile(Customer? customer, BuildContext modalCtx) {
    final bool isSelected = _activeCustomer?.id == customer?.id;
    final name = customer?.name ?? 'Walk-in Customer';
    final balanceKobo = customer == null
        ? 0
        : (ref.watch(walletBalancesKoboProvider).valueOrNull?[customer.id] ?? 0);
    final customerWallet = balanceKobo / 100.0;
    final isOwe = customerWallet < 0;

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
                    ? FontAwesomeIcons.userTag
                    : FontAwesomeIcons.user,
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
                          FontAwesomeIcons.nairaSign,
                          size: modalCtx.getRSize(10),
                          color: customerWallet == 0
                              ? success
                              : (isOwe ? danger : success),
                        ),
                        Text(
                          ' Bal: ${formatCurrency(customerWallet)}',
                          style: TextStyle(
                            fontSize: modalCtx.getRFontSize(12),
                            color: customerWallet == 0
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
                FontAwesomeIcons.circleCheck,
                color: Theme.of(context).colorScheme.primary,
                size: modalCtx.getRSize(18),
              ),
          ],
        ),
      ),
    );
  }

  void _editItem(BuildContext ctx, Map<String, dynamic> item) {
    EditItemModal.show(ctx, item);
  }

  void _showEditCrateDeposit() {
    final ctrl = TextEditingController(
      text: _crateDeposit == 0 ? '' : _crateDeposit.toInt().toString(),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(sheetCtx),
          child: DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            snap: true,
            snapSizes: const [0.5, 0.9],
            builder: (context, scrollController) {
              return GestureDetector(
                onTap: () {}, // Prevent tap from reaching the barrier
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(24),
                    context.getRSize(16),
                    context.getRSize(24),
                    context.bottomInset + 24,
                  ),
                  child: ListView(
                    controller: scrollController,
                    children: [
                      Center(
                        child: Container(
                          width: context.getRSize(40),
                          height: context.getRSize(4),
                          decoration: BoxDecoration(
                            color: _border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      SizedBox(height: context.getRSize(20)),
                      Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(context.getRSize(10)),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.7),
                                  Theme.of(context).colorScheme.primary,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              FontAwesomeIcons.beerMugEmpty,
                              size: context.getRSize(16),
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: context.getRSize(12)),
                          Text(
                            'Deposit Paid',
                            style: TextStyle(
                              fontSize: context.getRFontSize(18),
                              fontWeight: FontWeight.w800,
                              color: _text,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: context.getRSize(6)),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Enter the deposit amount paid for crates',
                          style: TextStyle(
                            fontSize: context.getRFontSize(13),
                            color: _subtext,
                          ),
                        ),
                      ),
                      SizedBox(height: context.getRSize(20)),
                      AppInput(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [CurrencyInputFormatter()],
                        autofocus: true,
                        prefixText: '₦ ',
                        hintText: '0',
                        fillColor: Theme.of(context).cardColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      SizedBox(height: context.getRSize(24)),
                      Row(
                        children: [
                          Expanded(
                            child: AppButton(
                              text: 'Cancel',
                              variant: AppButtonVariant.ghost,
                              onPressed: () => Navigator.pop(sheetCtx),
                            ),
                          ),
                          SizedBox(width: context.getRSize(12)),
                          Expanded(
                            child: AppButton(
                              text: 'Confirm',
                              variant: AppButtonVariant.primary,
                              onPressed: () {
                                final val = parseCurrency(ctrl.text);
                                setState(() => _crateDeposit = val);
                                Navigator.pop(sheetCtx);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
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
            color: large ? blueMain : _text,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
    // immediately. CrateGroups are no longer the gating identifier.
    final bottleItems = cartItems
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

    for (final mfrId in sortedMfrIds) {
      depositLines.add(
        _CrateDepositLine(
          label: mfrNames[mfrId]!,
          color: _cgColors[mfrId.hashCode.abs() % _cgColors.length],
          qty: mfrQtys[mfrId]!,
          amount: mfrAmounts[mfrId]!,
        ),
      );
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

    // Total = Subtotal + Deposit Paid (manually entered) - Credit
    // computedDeposit is informational only — not added to the payable total
    final tot = sub + _crateDeposit - customerCrateCredit;

    final customerName = _activeCustomer?.name ?? 'Walk-in Customer';
    final activeBalanceKobo = _activeCustomer == null
        ? 0
        : (ref
                .watch(walletBalancesKoboProvider)
                .valueOrNull?[_activeCustomer!.id] ??
            0);
    final customerWallet = activeBalanceKobo / 100.0;
    final isOwe = customerWallet < 0;

    return SharedScaffold(
      activeRoute: 'cart',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: const MenuButton(),
        title: const AppBarHeader(
          icon: FontAwesomeIcons.cartShopping,
          title: 'Cart',
          subtitle: 'Review Selection',
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
                      FontAwesomeIcons.trashCan,
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
                            ? FontAwesomeIcons.userTag
                            : FontAwesomeIcons.user,
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
                                FontAwesomeIcons.nairaSign,
                                size: context.getRSize(11),
                                color: customerWallet == 0
                                    ? success
                                    : (isOwe ? danger : success),
                              ),
                              Flexible(
                                child: Text(
                                  ' Bal: ₦${customerWallet.abs().toStringAsFixed(0)} ${customerWallet == 0 ? "clear" : (isOwe ? "overdue" : "credit")}',
                                  style: TextStyle(
                                    fontSize: context.getRFontSize(12),
                                    color: customerWallet == 0
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
                            FontAwesomeIcons.cartArrowDown,
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
                        ],
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
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
                                  : Colors.blue;
                              // Build card once, reused in both paths
                              final card = InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: _isClearing
                                    ? null
                                    : () => _editItem(context, item),
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
                                              ? FontAwesomeIcons.box
                                              : item['icon'] is IconData
                                              ? item['icon'] as IconData
                                              : IconData(
                                                  item['icon'] as int,
                                                  fontFamily:
                                                      'FontAwesomeSolid',
                                                  fontPackage:
                                                      'font_awesome_flutter',
                                                ),
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
                                          ],
                                        ),
                                      ),
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          formatCurrency(
                                            (((item['qty'] as num?)
                                                        ?.toDouble() ??
                                                    0.0) *
                                                ((item['price'] as num?)
                                                        ?.toDouble() ??
                                                    0.0)),
                                          ),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: context.getRFontSize(16),
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                        ),
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
                                    SizedBox(height: context.getRSize(8)),
                                    if (hasBottles) ...[
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
                                                        blueLight,
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
                                                        .beerMugEmpty,
                                                    size: context.getRSize(14),
                                                    color: Colors.white,
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
                                                    Row(
                                                      children: [
                                                        Container(
                                                          width: context
                                                              .getRSize(8),
                                                          height: context
                                                              .getRSize(8),
                                                          decoration:
                                                              BoxDecoration(
                                                                color:
                                                                    line.color,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                        ),
                                                        SizedBox(
                                                          width: context
                                                              .getRSize(8),
                                                        ),
                                                        Text(
                                                          '${line.label}  ×${line.qty.toStringAsFixed(1)}',
                                                          style: TextStyle(
                                                            fontSize: context
                                                                .getRFontSize(
                                                                  13,
                                                                ),
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            color: _subtext,
                                                          ),
                                                        ),
                                                      ],
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
                                    // Deposit Paid tappable button — always visible
                                    GestureDetector(
                                      onTap: () => _showEditCrateDeposit(),
                                      child: Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.symmetric(
                                          horizontal: context.getRSize(16),
                                          vertical: context.getRSize(14),
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.08),
                                              Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.04),
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.12),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
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
                                                        blueLight,
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
                                                        .beerMugEmpty,
                                                    size: context.getRSize(13),
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: context.getRSize(10),
                                                ),
                                                Text(
                                                  'Deposit Paid',
                                                  style: TextStyle(
                                                    fontSize: context
                                                        .getRFontSize(14),
                                                    fontWeight: FontWeight.w700,
                                                    color: _text,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            Row(
                                              children: [
                                                Text(
                                                  formatCurrency(_crateDeposit),
                                                  style: TextStyle(
                                                    fontSize: context
                                                        .getRFontSize(15),
                                                    fontWeight: FontWeight.w800,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: context.getRSize(6),
                                                ),
                                                Icon(
                                                  FontAwesomeIcons.penToSquare,
                                                  size: context.getRSize(13),
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
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
                                            icon: FontAwesomeIcons.floppyDisk,
                                            onPressed: _saveCurrentCart,
                                          ),
                                        ),
                                        SizedBox(width: context.getRSize(12)),
                                        Expanded(
                                          child: AppButton(
                                            text: 'Recall',
                                            variant: AppButtonVariant.outline,
                                            icon: FontAwesomeIcons
                                                .clockRotateLeft,
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
                                      icon: FontAwesomeIcons.checkToSlot,
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
                                                crateDeposit: _crateDeposit,
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
