import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CheckoutPage — shown after "Proceed to Checkout" in the cart.
// ─────────────────────────────────────────────────────────────────────────────

class CheckoutPage extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> cart;
  final double subtotal;
  final double crateDeposit;
  final double total;
  final Customer? customer;
  final VoidCallback? onCheckoutSuccess;

  const CheckoutPage({
    super.key,
    required this.cart,
    required this.subtotal,
    required this.crateDeposit,
    required this.total,
    this.customer,
    this.onCheckoutSuccess,
  });

  @override
  ConsumerState<CheckoutPage> createState() => _CheckoutPageState();
}

/// 3 payment methods:
/// - fullCash  → full amount paid now (cash or card), no balance added
/// - partialCash → partial payment, remainder added to customer balance
/// - credit    → full amount added to customer balance (disabled for walk-in)
enum PaymentType { fullCash, partialCash, credit }

class _CheckoutPageState extends ConsumerState<CheckoutPage> {
  PaymentType _paymentType = PaymentType.fullCash;
  bool _isWalletPayment = false;
  final TextEditingController _cashReceivedCtrl = TextEditingController();
  final ScreenshotController _screenshotCtrl = ScreenshotController();
  bool _paymentConfirmed = false;
  bool _isProcessing = false;
  Map<String, String> _manufacturerNames = {};
  String? _branchName;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  StreamSubscription<StoreData?>? _activeStoreSub;
  late final Customer? _initialCustomer;

  // Computed on confirm — passed to receipt

  double _amountPaid = 0;
  String _currentOrderId = '';

  late final CartService _cart;
  bool get _isWalkIn => _initialCustomer == null || _initialCustomer.isWalkIn;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    _initialCustomer = widget.customer;
    AppLogger.info(
      'CheckoutPage: Initializing with ${widget.cart.length} items. Total: ${widget.total}',
    );
    for (int i = 0; i < widget.cart.length; i++) {
      final item = widget.cart[i];
      AppLogger.debug(
        'CheckoutPage: Item [$i]: ${item['name']}, Price: ${item['price']}, Qty: ${item['qty']}',
      );
    }
    _loadManufacturers();
    _cart = ref.read(cartProvider);
    _cart.activeCustomer.addListener(_onCustomerChanged);
  }

  void _onCustomerChanged() {
    if (mounted) setState(() => _isWalletPayment = false);
  }

  Future<void> _loadManufacturers() async {
    final db = ref.read(databaseProvider);
    final nav = ref.read(navigationProvider);
    final auth = ref.read(authProvider);

    final storeId =
        nav.lockedStoreId.value ?? auth.currentUser?.storeId;

    // Stream-driven so a remote rename of the active store or a new
    // manufacturer arriving via realtime updates the receipt header / map
    // without a manual refresh.
    _manufacturersSub = db.inventoryDao.watchAllManufacturers().listen((list) {
      if (!mounted) return;
      setState(() {
        _manufacturerNames = {for (final m in list) m.id: m.name};
      });
    });

    if (storeId != null) {
      _activeStoreSub = (db.select(db.stores)
            ..where((t) => t.id.equals(storeId))
            ..limit(1))
          .watchSingleOrNull()
          .listen((w) {
        if (!mounted) return;
        setState(() => _branchName = w?.name);
      });
    }
  }

  @override
  void dispose() {
    _cart.activeCustomer.removeListener(_onCustomerChanged);
    _cashReceivedCtrl.dispose();
    _manufacturersSub?.cancel();
    _activeStoreSub?.cancel();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  String get _paymentLabel {
    switch (_paymentType) {
      case PaymentType.fullCash:
        return _isWalletPayment ? 'Wallet Payment' : 'Full Cash / Card';
      case PaymentType.partialCash:
        return 'Partial Cash / Card';
      case PaymentType.credit:
        return 'Credit Sale';
    }
  }

  String get _customerDisplayName =>
      _initialCustomer?.name ?? 'Walk-in Customer';

  double get _cashReceivedValue => parseCurrency(_cashReceivedCtrl.text);

  /// Live wallet balance (Naira) for the current customer, computed from the
  /// WalletTransactions ledger. Returns 0.0 for walk-ins or if the provider
  /// is still loading.
  double _walletBalanceFor(String? customerId) {
    if (customerId == null) return 0.0;
    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ??
        const <String, int>{};
    return (balances[customerId] ?? 0) / 100.0;
  }

  double get _currentCustomerWallet =>
      _isWalkIn ? 0.0 : _walletBalanceFor(_initialCustomer?.id);

  double get _dynamicNewCustomerWallet {
    final oldCustomerWallet = _currentCustomerWallet;
    double effectiveCash;
    switch (_paymentType) {
      case PaymentType.fullCash:
        // Wallet payment debits the wallet; cash payment leaves it unchanged
        effectiveCash = _isWalletPayment ? 0 : widget.total;
        break;
      case PaymentType.partialCash:
        effectiveCash = _cashReceivedValue;
        break;
      case PaymentType.credit:
        effectiveCash = 0;
        break;
    }
    return oldCustomerWallet - widget.total + effectiveCash;
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            size: context.getRSize(20),
            color: _text,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _paymentConfirmed ? 'Receipt' : 'Checkout',
          style: TextStyle(
            fontSize: context.getRFontSize(18),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: _paymentConfirmed ? _buildReceiptView() : _buildCheckoutForm(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CHECKOUT FORM
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildCheckoutForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(20),
        context.getRSize(20),
        context.getRSize(40),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Order Summary ─────────────────────────────────────────────
          _sectionLabel('Order Summary'),
          SizedBox(height: context.getRSize(12)),
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border),
            ),
            child: Column(
              children: [
                ...widget.cart.map(_orderItemTile),
                Divider(height: 1, color: _border),
                _summaryRow('Subtotal', widget.subtotal),
                _summaryRow('Crate Deposit', widget.crateDeposit),
                Divider(height: 1, color: _border),
                _summaryRow('Total', widget.total, bold: true, accent: true),
              ],
            ),
          ),

          SizedBox(height: context.getRSize(28)),
          // ── Customer Info ─────────────────────────────────────────────
          _sectionLabel('Customer'),
          SizedBox(height: context.getRSize(12)),
          Container(
            padding: EdgeInsets.all(context.getRSize(14)),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border),
            ),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(context.getRSize(10)),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _isWalkIn
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
                        _customerDisplayName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: context.getRFontSize(14),
                          color: _text,
                        ),
                      ),
                      if (!_isWalkIn && widget.customer != null) ...[
                        SizedBox(height: context.getRSize(2)),
                        Builder(
                          builder: (_) {
                            final w = _walletBalanceFor(widget.customer!.id);
                            return Text(
                              'Wallet Balance: ${formatCurrency(w)} ${w < 0 ? "(debt)" : "(credit)"}',
                              style: TextStyle(
                                fontSize: context.getRFontSize(12),
                                color: w < 0
                                    ? danger
                                    : w > 0
                                    ? success
                                    : _subtext,
                                fontWeight: FontWeight.w600,
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: context.getRSize(28)),
          // ── Payment Method ────────────────────────────────────────────
          _sectionLabel('Payment Method'),
          SizedBox(height: context.getRSize(12)),

          // 1. Full Cash / Card
          _paymentOption(
            PaymentType.fullCash,
            'Full Cash / Card Payment',
            'Full amount paid now — no balance added',
            FontAwesomeIcons.moneyBill,
          ),

          // Sub-options: Cash/Transfer vs Wallet — only for named customers
          if (_paymentType == PaymentType.fullCash && !_isWalkIn)
            _buildWalletSubOptions(),

          // 2. Partial Cash / Card
          _paymentOption(
            PaymentType.partialCash,
            'Partial Cash / Card Payment',
            _isWalkIn
                ? 'Not available for Walk-in customers'
                : 'Enter amount paid — remainder added to balance',
            FontAwesomeIcons.moneyBillTransfer,
            disabled: _isWalkIn,
          ),

          // Partial amount input + live remaining
          if (_paymentType == PaymentType.partialCash) ...[
            SizedBox(height: context.getRSize(16)),
            AppInput(
              controller: _cashReceivedCtrl,
              labelText: 'Amount Paid Now',
              hintText: '₦ Enter amount',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
              onChanged: (v) => setState(() {}),
            ),
            SizedBox(height: context.getRSize(10)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(16),
                vertical: context.getRSize(12),
              ),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Remaining Wallet Balance',
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w700,
                      color: _text,
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final newCustomerWallet = _dynamicNewCustomerWallet;
                      final isDebt = newCustomerWallet < 0;
                      final balStr = formatCurrency(newCustomerWallet);
                      final valColor = isDebt ? Colors.amber.shade700 : success;

                      return Text(
                        newCustomerWallet == 0 ? formatCurrency(0) : balStr,
                        style: TextStyle(
                          fontSize: context.getRFontSize(15),
                          fontWeight: FontWeight.w800,
                          color: newCustomerWallet < 0 ? danger : valColor,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(4)),
            if (!_isWalkIn)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
                child: Text(
                  'Remaining will be added to ${_initialCustomer!.name}\'s balance',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            if (_isWalkIn)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
                child: Text(
                  'Remaining will appear on the receipt only (Walk-in)',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],

          // 3. Credit Sale — disabled for walk-in
          _paymentOption(
            PaymentType.credit,
            'Register as Credit Sale',
            _isWalkIn
                ? 'Not available for Walk-in customers'
                : 'Full amount added to customer\'s wallet',
            FontAwesomeIcons.fileInvoiceDollar,
            disabled: _isWalkIn,
          ),

          SizedBox(height: context.getRSize(32)),
          AppButton(
            text: 'Confirm Payment',
            variant: AppButtonVariant.primary,
            isLoading: _isProcessing,
            icon: FontAwesomeIcons.check,
            onPressed: _confirmPayment,
          ),
        ],
      ),
    );
  }

  // ── Cart staleness ─────────────────────────────────────────────────────────
  Future<List<CartStaleItem>> _detectCartStaleness() async {
    final lines = <CartLineSnapshot>[];
    for (final item in widget.cart) {
      final id = item['id'] as String?;
      if (id == null || id.isEmpty) continue; // Quick-sale: no DB product
      final version = item['version'] as int?;
      final unitPriceKobo =
          (item['unitPriceKobo'] as int?) ??
          ((item['price'] as num).toDouble() * 100).round();
      if (version == null) continue; // Pre-versioning entry; skip check.
      lines.add(
        CartLineSnapshot(
          productId: id,
          cartVersion: version,
          cartUnitPriceKobo: unitPriceKobo,
        ),
      );
    }
    if (lines.isEmpty) return const [];
    return ref.read(orderServiceProvider).checkCartStaleness(lines);
  }

  Future<bool> _showStalenessDialog(List<CartStaleItem> stale) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Prices changed'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The following items were updated since you added '
                'them to the cart:',
              ),
              const SizedBox(height: 12),
              ...stale.map(
                (s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${s.productName}: ${formatCurrency(s.oldPriceKobo / 100.0)} '
                    '→ ${formatCurrency(s.newPriceKobo / 100.0)}',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept new prices'),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ── Confirm payment logic ──────────────────────────────────────────────────
  Future<void> _confirmPayment() async {
    // Pre-flight: detect price/version drift since items were added to cart.
    // Cashier accepts new prices or cancels back to the cart.
    final stale = await _detectCartStaleness();
    if (!mounted) return;
    if (stale.isNotEmpty) {
      final accepted = await _showStalenessDialog(stale);
      if (!accepted) return;
      ref.read(cartProvider).acceptStaleness({
        for (final s in stale)
          s.productId: (
            unitPriceKobo: s.newPriceKobo,
            version: s.currentVersion,
          ),
      });
      // Cart values changed — let the user re-confirm against the new total.
      if (mounted) {
        AppNotification.showError(
          context,
          'Prices updated. Review the cart and confirm again.',
        );
      }
      return;
    }

    // Walk-in validation
    if (_isWalkIn && _paymentType != PaymentType.fullCash) {
      AppNotification.showError(context, 'Walk-in customers must pay in full');
      return;
    }

    // Wallet payment validation
    if (_paymentType == PaymentType.fullCash && _isWalletPayment) {
      final walletBalance = _currentCustomerWallet;
      if (walletBalance < widget.total) {
        AppNotification.showError(
          context,
          'Insufficient wallet balance. Use Partial Payment instead.',
        );
        return;
      }
    }

    // Validation
    if (_paymentType == PaymentType.partialCash && _cashReceivedValue <= 0) {
      AppNotification.showError(context, 'Please enter the amount paid');
      return;
    }

    // Debt limit validations (partial cash / credit sale only)
    if (_paymentType == PaymentType.partialCash ||
        _paymentType == PaymentType.credit) {
      final customer = _initialCustomer!;
      final limitKobo = customer.walletLimitKobo;

      // Block if no debt limit has been set
      if (limitKobo <= 0) {
        AppNotification.showError(
          context,
          '${customer.name} has no debt limit set. '
          'Set a debt limit in the customer profile before allowing credit or partial payments.',
        );
        return;
      }

      // Block if this purchase would push the customer over their debt limit
      final totalKobo = (widget.total * 100).round();
      final amountPaidKobo = _paymentType == PaymentType.partialCash
          ? (_cashReceivedValue * 100).round()
          : 0;
      final remainingKobo = totalKobo - amountPaidKobo;
      final currentBalanceKobo = await ref
          .read(databaseProvider)
          .customersDao
          .getWalletBalanceKobo(customer.id);
      final newBalanceKobo = currentBalanceKobo - remainingKobo;

      if (newBalanceKobo < -limitKobo) {
        final overByKobo = (-newBalanceKobo) - limitKobo;
        if (mounted) {
          AppNotification.showError(
            context,
            'This sale exceeds ${customer.name}\'s debt limit of '
            '${formatCurrency(limitKobo / 100.0)}. '
            'Over limit by ${formatCurrency(overByKobo / 100.0)}.',
          );
        }
        return;
      }
    }

    setState(() => _isProcessing = true);

    try {
      // Compute amounts in kobo
      final totalKobo = (widget.total * 100).round();
      int amountPaidKobo;

      switch (_paymentType) {
        case PaymentType.fullCash:
          // Wallet payment: amountPaidKobo=0 so the full amount is debited
          // from the customer wallet (same mechanism as credit sale)
          amountPaidKobo = _isWalletPayment ? 0 : totalKobo;
          break;
        case PaymentType.partialCash:
          amountPaidKobo = (_cashReceivedValue * 100).round();
          break;
        case PaymentType.credit:
          amountPaidKobo = 0;
          break;
      }

      // ── Call atomic transaction ──────────────────────────────────────
      final auth = ref.read(authProvider);
      final nav = ref.read(navigationProvider);
      final storeId =
          nav.lockedStoreId.value ?? auth.currentUser?.storeId;

      // Ensure branch name is resolved before proceeding to receipt
      if (_branchName == null && storeId != null) {
        final db = ref.read(databaseProvider);
        final w = await (db.select(
          db.stores,
        )..where((t) => t.id.equals(storeId))).getSingleOrNull();
        if (mounted) setState(() => _branchName = w?.name);
      }

      final orderNo = await ref
          .read(orderServiceProvider)
          .addOrder(
            customerId: _initialCustomer?.id,
            cart: widget.cart,
            totalAmountKobo: totalKobo,
            amountPaidKobo: amountPaidKobo,
            paymentType: _paymentLabel,
            staffId: auth.currentUser?.id,
            storeId: storeId,
            crateDepositPaidKobo: (widget.crateDeposit * 100).round(),
            paymentSubType: _isWalletPayment ? 'wallet' : 'cash',
          );

      // ── Success Flow ────────────────────────────────────────────────
      if (mounted) {
        setState(() {
          _amountPaid = amountPaidKobo / 100.0;
          _paymentConfirmed = true;
          _currentOrderId = orderNo;
        });

        // Clear cart for next sale
        final cart = ref.read(cartProvider);
        cart.clear();
        cart.setActiveCustomer(null);

        widget.onCheckoutSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Checkout failed: ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECEIPT VIEW (shown after payment confirmed)
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildReceiptView() {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.getRSize(20)),
            child: Screenshot(
              controller: _screenshotCtrl,
              child: ReceiptWidget(
                orderId: _currentOrderId,
                cart: widget.cart,
                subtotal: widget.subtotal,
                crateDeposit: widget.crateDeposit,
                total: widget.total,
                paymentMethod: _paymentLabel,
                customerName: _customerDisplayName,
                customerAddress: _initialCustomer?.addressText ?? 'N/A',
                customerPhone: _initialCustomer?.phone,
                cashReceived: _amountPaid,
                walletBalance: _isWalkIn ? null : _dynamicNewCustomerWallet,
                riderName: 'Pick-up Order',
                manufacturerNames: _manufacturerNames,
                branchName: _branchName,
              ),
            ),
          ),
        ),
        _buildReceiptActions(),
      ],
    );
  }

  Widget _buildReceiptActions() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(32),
      ),
      decoration: BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Column(
        children: [
          Text(
            'Receipt Options',
            style: TextStyle(
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.bold,
              color: _text,
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          Row(
            children: [
              Expanded(
                child: _receiptButton(
                  'Print Receipt',
                  FontAwesomeIcons.print,
                  Theme.of(context).colorScheme.primary,
                  _printReceipt,
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _receiptButton(
                  'Share Receipt',
                  FontAwesomeIcons.shareNodes,
                  success,
                  _shareReceipt,
                ),
              ),
            ],
          ),
          AppButton(
            text: 'Done — Back to POS',
            variant: AppButtonVariant.ghost,
            onPressed: () {
              if (!mounted) return;
              Navigator.of(context).pop();
              ref.read(navigationProvider).setIndex(1);
            },
          ),
        ],
      ),
    );
  }

  Widget _receiptButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(14)),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, size: context.getRSize(20), color: color),
            SizedBox(height: context.getRSize(6)),
            Text(
              label,
              style: TextStyle(
                fontSize: context.getRFontSize(11),
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Receipt actions ────────────────────────────────────────────────────────

  Future<void> _shareReceipt() async {
    try {
      final Uint8List? imageBytes = await _screenshotCtrl.capture(
        delay: const Duration(milliseconds: 50),
        pixelRatio: 3.0,
      );
      if (imageBytes == null) {
        if (!mounted) return;
        AppNotification.showError(context, 'Failed to capture receipt image');
        return;
      }

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/reebaplus_pos_receipt_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(imageBytes);

      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Reebaplus POS Receipt');
    } catch (e) {
      if (!mounted) return;
      AppNotification.showError(context, 'Error sharing receipt: $e');
    }
  }

  Future<void> _printReceipt() async {
    try {
      final printer = ref.read(printerServiceProvider);

      // Request Bluetooth permissions first.
      final granted = await printer.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        AppNotification.showError(context, 'Bluetooth permissions denied');
        return;
      }

      AppNotification.showInfo(context, 'Preparing receipt...');

      final List<int> receiptBytes = await ThermalReceiptService.buildReceipt(
        orderId: _currentOrderId,
        cart: widget.cart,
        subtotal: widget.subtotal,
        crateDeposit: widget.crateDeposit,
        total: widget.total,
        paymentMethod: _paymentLabel,
        customerName: _customerDisplayName,
        customerAddress: widget.customer?.addressText,
        customerPhone: widget.customer?.phone,
        cashReceived: _amountPaid,
        walletBalance: _isWalkIn ? null : _dynamicNewCustomerWallet,
        riderName: 'Pick-up Order',
        branchName: _branchName,
      );

      if (!mounted) return;

      // Proactively check connection before writing.
      final connected = await printer.isConnected;
      if (connected) {
        // Already connected — try printing directly.
        final success = await printer.printBytesDirectly(receiptBytes);
        if (success) {
          if (!mounted) return;
          AppNotification.showSuccess(context, 'Print successful');
          return;
        }
      }

      // Not connected (or direct print failed) — show picker immediately.
      if (!mounted) return;
      _showPrinterPicker(printer, receiptBytes);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Print error: $e');
      }
    }
  }

  void _showPrinterPicker(dynamic printer, List<int> receiptBytes) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => PrinterPicker(
        onSelected: (device) async {
          if (!mounted) return;
          Navigator.pop(context);

          if (!mounted) return;
          AppNotification.showSuccess(
            context,
            'Connecting to ${device.name}...',
          );

          final connected = await printer.connect(device.macAdress);
          if (!mounted) return;

          if (connected) {
            await printer.saveLastConnectedMac(device.macAdress);
            final success = await printer.printBytesDirectly(receiptBytes);
            if (!mounted) return;
            if (success) {
              AppNotification.showSuccess(context, 'Print successful');
            } else {
              AppNotification.showError(context, 'Print failed after connect');
            }
          } else {
            AppNotification.showError(
              context,
              'Failed to connect to ${device.name}',
            );
          }
        },
      ),
    );
  }

  // ── Wallet sub-options (shown under Full Cash when customer is named) ───────

  Widget _buildWalletSubOptions() {
    final walletBalance = _walletBalanceFor(widget.customer?.id);
    final sufficient = walletBalance >= widget.total;

    return Padding(
      padding: EdgeInsets.only(
        left: context.getRSize(4),
        right: context.getRSize(4),
        bottom: context.getRSize(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _walletChip(
                'Cash / Transfer',
                !_isWalletPayment,
                () => setState(() => _isWalletPayment = false),
              ),
              SizedBox(width: context.getRSize(10)),
              _walletChip(
                'Pay from Wallet',
                _isWalletPayment,
                () => setState(() => _isWalletPayment = true),
              ),
            ],
          ),
          if (_isWalletPayment) ...[
            SizedBox(height: context.getRSize(12)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(16),
                vertical: context.getRSize(12),
              ),
              decoration: BoxDecoration(
                color: sufficient
                    ? success.withValues(alpha: 0.08)
                    : danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: sufficient
                      ? success.withValues(alpha: 0.3)
                      : danger.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Wallet Balance',
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w700,
                      color: _text,
                    ),
                  ),
                  Text(
                    formatCurrency(walletBalance),
                    style: TextStyle(
                      fontSize: context.getRFontSize(15),
                      fontWeight: FontWeight.w800,
                      color: sufficient ? success : danger,
                    ),
                  ),
                ],
              ),
            ),
            if (!sufficient) ...[
              SizedBox(height: context.getRSize(6)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
                child: Text(
                  'Insufficient balance (${formatCurrency(walletBalance - widget.total)} short). '
                  'Use Partial Payment instead.',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: danger,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _walletChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(8),
        ),
        decoration: BoxDecoration(
          color: selected ? blueMain.withValues(alpha: 0.12) : _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? blueMain : _border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.getRFontSize(13),
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            color: selected ? blueMain : _subtext,
          ),
        ),
      ),
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: context.getRFontSize(16),
        fontWeight: FontWeight.w800,
        color: _text,
      ),
    );
  }

  Widget _orderItemTile(Map<String, dynamic> item) {
    // Robustly parse values to prevent crashes on malformed data
    final rawPrice = item['price'];
    final double price = rawPrice is num
        ? rawPrice.toDouble()
        : double.tryParse(rawPrice.toString()) ?? 0.0;

    final rawQty = item['qty'];
    final double qty = rawQty is num
        ? rawQty.toDouble()
        : double.tryParse(rawQty.toString()) ?? 0.0;

    final int lineTotal = (price * qty).toInt();

    final rawColor = item['color'];
    Color itemColor = Theme.of(context).colorScheme.primary;
    if (rawColor is Color) {
      itemColor = rawColor;
    } else if (rawColor is String && rawColor.isNotEmpty) {
      try {
        final hex = rawColor.startsWith('#')
            ? rawColor.replaceFirst('#', '0xFF')
            : rawColor.length == 6 || rawColor.length == 8
            ? '0xFF$rawColor'
            : rawColor;
        itemColor = Color(
          int.parse(hex.startsWith('0x') ? hex : '0xFF$hex', radix: 16),
        );
      } catch (_) {
        itemColor = Theme.of(context).colorScheme.primary;
      }
    }

    final rawIcon = item['icon'];
    final itemIcon = rawIcon is IconData
        ? rawIcon
        : rawIcon is int
        ? IconData(
            rawIcon,
            fontFamily: 'FontAwesomeSolid',
            fontPackage: 'font_awesome_flutter',
          )
        : FontAwesomeIcons.box;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(10),
      ),
      child: Row(
        children: [
          Container(
            width: context.getRSize(38),
            height: context.getRSize(38),
            decoration: BoxDecoration(
              color: itemColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(itemIcon, color: itemColor, size: context.getRSize(18)),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['name'],
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(14),
                    color: _text,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${qty.toStringAsFixed(1)} × ${formatCurrency(price)}',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                  ),
                ),
              ],
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatCurrency(lineTotal),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(14),
                color: _text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    double value, {
    bool bold = false,
    bool accent = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(bold ? 16 : 14),
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: bold ? _text : _subtext,
            ),
          ),
          Text(
            formatCurrency(value),
            style: TextStyle(
              fontSize: context.getRFontSize(bold ? 18 : 14),
              fontWeight: FontWeight.w800,
              color: accent ? blueMain : _text,
            ),
          ),
        ],
      ),
    );
  }

  /// Payment option tile.
  /// [disabled] is true for Credit Sale when walk-in customer.
  Widget _paymentOption(
    PaymentType type,
    String label,
    String subLabel,
    IconData icon, {
    bool disabled = false,
  }) {
    final active = !disabled && _paymentType == type;
    final effectiveColor = disabled ? _subtext : (active ? blueMain : _text);
    final iconColor = disabled ? _subtext : (active ? blueMain : _subtext);

    return GestureDetector(
      onTap: disabled
          ? null
          : () => setState(() {
              _paymentType = type;
              if (type != PaymentType.fullCash) _isWalletPayment = false;
            }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: EdgeInsets.only(bottom: context.getRSize(10)),
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: disabled
              ? _border.withValues(alpha: 0.10)
              : active
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: disabled
                ? _border.withValues(alpha: 0.4)
                : active
                ? blueMain
                : _border,
            width: active ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(42),
              height: context.getRSize(42),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: context.getRSize(18), color: iconColor),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: active ? FontWeight.bold : FontWeight.w600,
                      fontSize: context.getRFontSize(14),
                      color: effectiveColor,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    subLabel,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: disabled ? danger : _subtext,
                      fontStyle: disabled ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
            // Radio dot
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: context.getRSize(22),
              height: context.getRSize(22),
              decoration: BoxDecoration(
                color: active ? blueMain : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: disabled
                      ? _border.withValues(alpha: 0.4)
                      : active
                      ? blueMain
                      : _border,
                  width: 2,
                ),
              ),
              child: active
                  ? Icon(
                      Icons.check,
                      size: context.getRSize(14),
                      color: Colors.white,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
