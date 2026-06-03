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
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
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
  // §14.2 Step 2 — chosen receiving account; null falls back to Cash Till.
  String? _selectedFundsAccountId;
  // §14.1 — opt in to printing wallet info on the receipt. Off by default;
  // only meaningful for registered customers (walk-ins have no wallet, §14.3).
  bool _addWalletInfoToReceipt = false;
  final TextEditingController _cashReceivedCtrl = TextEditingController();
  final ScreenshotController _screenshotCtrl = ScreenshotController();
  bool _paymentConfirmed = false;
  bool _isProcessing = false;
  // True while a receipt print is in flight — drives the persistent blue
  // "Printing receipt…" banner on the receipt view (no toast, no spinner).
  bool _isPrinting = false;
  Map<String, String> _manufacturerNames = {};
  String? _branchName;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  StreamSubscription<StoreData?>? _activeStoreSub;
  late final Customer? _initialCustomer;

  // Computed on confirm — passed to receipt

  double _amountPaid = 0;
  String _currentOrderId = '';

  /// Customer's wallet balance (Naira) AFTER the sale's two legs, captured at
  /// confirm time and shown on the receipt. Snapshotting avoids the pre-sale
  /// projection double-counting the just-posted dual-leg rows (§14.3, bug #5/#6).
  /// Null for walk-ins (no wallet).
  double? _receiptWalletBalance;

  /// §14.2 bug #4 — the cashier confirmed the outstanding cash (after the wallet
  /// credit is applied) was collected. Required before the apply-credit flow can
  /// confirm.
  bool _outstandingPaidConfirmed = false;

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
    // §14.2 — default a registered customer to "Pay from Wallet". Walk-ins have
    // no wallet (hard rule 14), so they stay on Cash / Card. When the customer
    // has no wallet credit the existing sub-options surface the "no credit"
    // hint and the cashier switches to Cash / Card.
    _isWalletPayment = !_isWalkIn;
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
    if (mounted) {
      setState(() {
        _isWalletPayment = false;
        _outstandingPaidConfirmed = false;
      });
    }
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
      _activeStoreSub = db.storesDao.watchStore(storeId).listen((w) {
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

  /// Live wallet balance (kobo) for the current customer (0 for walk-ins).
  /// Used for the apply-credit math and the debt-limit check so they avoid a
  /// fresh awaited DB read (which made the over-limit error fire too late, #7).
  int get _currentCustomerWalletKobo {
    final id = _initialCustomer?.id;
    if (_isWalkIn || id == null) return 0;
    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ??
        const <String, int>{};
    return balances[id] ?? 0;
  }

  /// Live debt limit (kobo) for the current customer. Reads from the live
  /// CustomerService list so a limit raised before/while this checkout was open
  /// is honoured — the `_initialCustomer` snapshot captured at init (and the
  /// Customer carried through the cart) can be stale. The wallet *balance* is
  /// already read live, so reading the limit live too keeps the two sides of
  /// the debt-limit check consistent. Falls back to the snapshot if the
  /// customer isn't in the live list yet.
  int get _currentCustomerWalletLimitKobo {
    final id = _initialCustomer?.id;
    if (id == null) return _initialCustomer?.walletLimitKobo ?? 0;
    final live = ref.read(customerServiceProvider).getById(id);
    return live?.walletLimitKobo ?? _initialCustomer?.walletLimitKobo ?? 0;
  }

  int get _totalKobo => (widget.total * 100).round();

  /// Wallet credit (kobo) available to apply toward an order (0 if none / debt).
  int get _walletCreditKobo {
    final k = _currentCustomerWalletKobo;
    return k > 0 ? k : 0;
  }

  /// Outstanding (kobo) after the wallet credit is applied to the order.
  int get _outstandingAfterCreditKobo =>
      (_totalKobo - _walletCreditKobo).clamp(0, _totalKobo);

  /// §14.2 bug #4 — "Pay from Wallet" chosen but the credit only PARTIALLY
  /// covers the order: apply the credit (wallet → ₦0) and collect the
  /// outstanding into a Funds account. (When credit fully covers, it's the
  /// plain pay-from-wallet path; when there's no credit, wallet payment is
  /// blocked.)
  bool get _isApplyCreditFlow =>
      _paymentType == PaymentType.fullCash &&
      _isWalletPayment &&
      !_isWalkIn &&
      _walletCreditKobo > 0 &&
      _walletCreditKobo < _totalKobo;

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
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
        context.getRSize(40) + context.deviceBottomInset,
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

          // §14.2 Step 2: pick the receiving account — only when cash / card /
          // transfer actually lands in an account (not a wallet or credit
          // sale). Apply-credit only collects cash when "outstanding paid" is
          // ticked; left unticked the shortfall becomes debt, so no account.
          if ((_paymentType == PaymentType.fullCash && !_isWalletPayment) ||
              _paymentType == PaymentType.partialCash ||
              (_isApplyCreditFlow && _outstandingPaidConfirmed))
            _buildAccountPicker(),

          // §14.1 — "Add wallet info to receipt" (off by default). Only shown
          // for registered customers; walk-ins have no wallet (§14.3).
          if (!_isWalkIn) ...[
            SizedBox(height: context.getRSize(20)),
            _buildWalletInfoCheckbox(),
          ],

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
      final priceTier = (item['priceTier'] as String?) ?? 'retailer';
      if (version == null) continue; // Pre-versioning entry; skip check.
      lines.add(
        CartLineSnapshot(
          productId: id,
          cartVersion: version,
          cartUnitPriceKobo: unitPriceKobo,
          priceTier: priceTier,
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
    // Cashier accepts new prices or cancels back to the cart. This runs before
    // the main try below, so guard it on its own — a thrown DB error here must
    // flash, not silently kill the checkout button.
    final List<CartStaleItem> stale;
    try {
      stale = await _detectCartStaleness();
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not verify cart prices: $e');
      }
      return;
    }
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
      // The cart provider now holds the new prices, but THIS page's totals were
      // snapshotted at construction — `widget.cart` / `widget.total` are
      // immutable and `acceptStaleness` rebuilt the cart with fresh map
      // instances, so they never update here. Re-confirming on this page would
      // re-flag the same lines forever. Return to the cart (its totals are
      // live) so the cashier reviews the new prices and checks out again.
      if (mounted) {
        AppNotification.showInfo(
          context,
          'Prices updated. Review the cart and check out again.',
        );
        Navigator.of(context).pop();
      }
      return;
    }

    // Walk-in validation
    if (_isWalkIn && _paymentType != PaymentType.fullCash) {
      AppNotification.showError(context, 'Walk-in customers must pay in full');
      return;
    }

    // Wallet payment validation (§14.2)
    if (_paymentType == PaymentType.fullCash && _isWalletPayment) {
      if (_walletCreditKobo <= 0) {
        AppNotification.showError(
          context,
          'No wallet credit to pay from. Use Cash / Card or Partial Payment.',
        );
        return;
      }
      // Apply-credit flow (bug #4): the credit only partly covers the order.
      // Either the cashier ticks "outstanding paid" (the rest is collected as
      // cash), or the box is left unticked and the outstanding is booked as
      // debt on the customer's wallet — allowed only while it stays within
      // their debt limit (same gate as a partial/credit sale).
      if (_isApplyCreditFlow && !_outstandingPaidConfirmed) {
        final customer = _initialCustomer!;
        final limitKobo = _currentCustomerWalletLimitKobo;

        // No limit set → can't carry the debt; require the cash be collected.
        if (limitKobo <= 0) {
          AppNotification.showError(
            context,
            '${customer.name} has no debt limit set. Tick "outstanding paid" '
            'to collect the cash, or set a debt limit in the customer profile.',
          );
          return;
        }

        // Wallet goes to (current credit − full total); the shortfall is the
        // outstanding that becomes debt. Block if it breaches the limit.
        final newBalanceKobo = _currentCustomerWalletKobo - _totalKobo;
        if (newBalanceKobo < -limitKobo) {
          final overByKobo = (-newBalanceKobo) - limitKobo;
          AppNotification.showError(
            context,
            'The outstanding exceeds ${customer.name}\'s debt limit of '
            '${formatCurrency(limitKobo / 100.0)}. '
            'Over limit by ${formatCurrency(overByKobo / 100.0)}. '
            'Tick "outstanding paid" to collect the cash instead.',
          );
          return;
        }
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
      final limitKobo = _currentCustomerWalletLimitKobo;

      // Block if no debt limit has been set
      if (limitKobo <= 0) {
        AppNotification.showError(
          context,
          '${customer.name} has no debt limit set. '
          'Set a debt limit in the customer profile before allowing credit or partial payments.',
        );
        return;
      }

      // Block if this purchase would push the customer over their debt limit.
      // Read the balance synchronously from the live ledger (no awaited DB
      // round-trip) so the over-limit error always flashes — previously the
      // await let the message drop behind an `if (mounted)` guard and the sale
      // just went silent (#7).
      final totalKobo = (widget.total * 100).round();
      final amountPaidKobo = _paymentType == PaymentType.partialCash
          ? (_cashReceivedValue * 100).round()
          : 0;
      final remainingKobo = totalKobo - amountPaidKobo;
      final currentBalanceKobo = _currentCustomerWalletKobo;
      final newBalanceKobo = currentBalanceKobo - remainingKobo;

      if (newBalanceKobo < -limitKobo) {
        final overByKobo = (-newBalanceKobo) - limitKobo;
        AppNotification.showError(
          context,
          'This sale exceeds ${customer.name}\'s debt limit of '
          '${formatCurrency(limitKobo / 100.0)}. '
          'Over limit by ${formatCurrency(overByKobo / 100.0)}.',
        );
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
          if (_isWalletPayment) {
            // Pay from wallet. Apply-credit (bug #4) with the box ticked: the
            // credit only partly covers, so collect the outstanding now (it
            // flows through the wallet as a credit leg and credits the chosen
            // Funds account). Otherwise — credit fully covers, OR apply-credit
            // with the box left unticked — nothing is paid now and the full
            // total debits the wallet credit, taking it negative by the
            // outstanding (the debt the customer now owes).
            amountPaidKobo = (_isApplyCreditFlow && _outstandingPaidConfirmed)
                ? _outstandingAfterCreditKobo
                : 0;
          } else {
            amountPaidKobo = totalKobo;
          }
          break;
        case PaymentType.partialCash:
          amountPaidKobo = (_cashReceivedValue * 100).round();
          break;
        case PaymentType.credit:
          amountPaidKobo = 0;
          break;
      }

      // Snapshot the wallet balance BEFORE the legs post so the receipt shows
      // the true post-sale net (old + paid − total) instead of the pre-sale
      // projection re-applied on top of the just-written rows (#5/#6).
      final oldWalletKobo = _currentCustomerWalletKobo;

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

      // §14.2 Step 2: the receiving Funds Register account. Defaults to the
      // store's Cash Till when the cashier didn't pick one. The business date
      // buckets the credit (the day is guaranteed open — the POS gate enforced
      // it before checkout was reachable).
      String? fundsAccountId = _selectedFundsAccountId;
      if (fundsAccountId == null && storeId != null) {
        final accounts = await ref
            .read(databaseProvider)
            .fundsAccountsDao
            .getActiveAccountsForStore(storeId);
        if (accounts.isNotEmpty) {
          final till = accounts.where((a) => a.accountType == 'cash_till');
          fundsAccountId = (till.isNotEmpty ? till.first : accounts.first).id;
        }
      }
      final businessDate = ref.read(todaysBusinessDateProvider).valueOrNull;

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
            discountKobo: widget.cart.fold<int>(
              0,
              (s, i) => s + ((i['discountKobo'] as int?) ?? 0),
            ),
            // Apply-credit (bug #4) collects cash for the outstanding ONLY when
            // the box was ticked → 'cash' sub-type that credits a Funds
            // account. A fully covered wallet payment, or an apply-credit left
            // as debt (box unticked), is the 'wallet' sub-type — no cash lands,
            // the full total debits the wallet and the shortfall becomes debt.
            paymentSubType: (_isWalletPayment &&
                    !(_isApplyCreditFlow && _outstandingPaidConfirmed))
                ? 'wallet'
                : 'cash',
            fundsAccountId: fundsAccountId,
            businessDate: businessDate,
          );

      // ── Success Flow ────────────────────────────────────────────────
      if (mounted) {
        setState(() {
          _amountPaid = amountPaidKobo / 100.0;
          // True post-sale wallet net = old + credit(paid) − debit(total).
          // Walk-ins have no wallet (§14.3).
          _receiptWalletBalance =
              _isWalkIn ? null : (oldWalletKobo + amountPaidKobo - totalKobo) / 100.0;
          _paymentConfirmed = true;
          _currentOrderId = orderNo;
        });

        // Clear cart for next sale
        final cart = ref.read(cartProvider);
        cart.clear();
        cart.setActiveCustomer(null);

        widget.onCheckoutSuccess?.call();

        // Auto-print the receipt the moment the sale is confirmed. Fire-and-
        // forget: _printReceipt() is self-contained (shows the blue "Printing
        // receipt…" banner, auto-connects to the saved/paired printer, and
        // falls back to the picker) and must not block the confirm handler.
        // widget.cart is a snapshot, so it survives the cart.clear() above.
        unawaited(_printReceipt());
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
        // Persistent blue print-progress banner. Fades in/out (house rule:
        // fade transitions, no rotating spinners) and stays while _isPrinting.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _isPrinting
              ? _buildPrintingBanner()
              : const SizedBox.shrink(),
        ),
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
                walletBalance: _receiptWalletBalance,
                showWalletInfo: !_isWalkIn && _addWalletInfoToReceipt,
                riderName: 'Pick-up Order',
                manufacturerNames: _manufacturerNames,
                branchName: _branchName,
                businessName: ref.watch(currentBusinessNameProvider),
              ),
            ),
          ),
        ),
        _buildReceiptActions(),
      ],
    );
  }

  /// Blue in-progress banner pinned at the top of the receipt while a print is
  /// running. A static print glyph (not a spinner) keeps to the house loading
  /// convention; the AnimatedSwitcher in _buildReceiptView fades it in/out.
  Widget _buildPrintingBanner() {
    return Container(
      width: double.infinity,
      color: Colors.blue.shade600,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(20),
        vertical: context.getRSize(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FontAwesomeIcons.print,
            size: context.getRSize(16),
            color: Colors.white,
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            'Printing receipt…',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: context.getRFontSize(14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptActions() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(32) + context.deviceBottomInset,
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
    if (!mounted) return;
    // Show the persistent blue "Printing receipt…" banner immediately — on
    // auto-print right after Confirm Payment and on a manual reprint tap. It
    // stays until this method's finally clears it. No reprintDate is passed
    // below, so this checkout receipt never stamps REPRINTED.
    setState(() => _isPrinting = true);
    try {
      final printer = ref.read(printerServiceProvider);

      // Request Bluetooth permissions first.
      final granted = await printer.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        AppNotification.showError(context, 'Bluetooth permissions denied');
        return;
      }

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
        showWalletInfo: !_isWalkIn && _addWalletInfoToReceipt,
        riderName: 'Pick-up Order',
        branchName: _branchName,
        businessName: ref.read(currentBusinessNameProvider),
      );

      if (!mounted) return;

      // Auto-print: reuse the live connection, otherwise auto-connect to the
      // last-used / paired printer — printBytes() handles both. Only when that
      // fails do we pull up the picker so the user can choose the right one.
      final printed = await printer.printBytes(receiptBytes);
      if (!mounted) return;
      if (printed) {
        AppNotification.showSuccess(context, 'Print successful');
        return;
      }

      _showPrinterPicker(printer, receiptBytes);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Print error: $e');
      }
    } finally {
      if (mounted) setState(() => _isPrinting = false);
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
          // Re-arm the print-progress banner for the manual connect + print.
          setState(() => _isPrinting = true);
          AppNotification.showSuccess(
            context,
            'Connecting to ${device.name}...',
          );

          // Wrap the connect/print so a thrown exception flashes an error
          // instead of dying silently.
          try {
            final connected = await printer.connect(device.macAdress);
            if (!mounted) return;

            if (connected) {
              await printer.saveLastConnectedMac(device.macAdress);
              final success = await printer.printBytesDirectly(receiptBytes);
              if (!mounted) return;
              if (success) {
                AppNotification.showSuccess(context, 'Print successful');
              } else {
                AppNotification.showError(
                  context,
                  'Print failed after connect',
                );
              }
            } else {
              AppNotification.showError(
                context,
                'Failed to connect to ${device.name}',
              );
            }
          } catch (e) {
            if (mounted) {
              AppNotification.showError(context, 'Print error: $e');
            }
          } finally {
            if (mounted) setState(() => _isPrinting = false);
          }
        },
      ),
    );
  }

  // ── Wallet sub-options (shown under Full Cash when customer is named) ───────

  /// §14.2 Step 2 — receiving-account picker. Lists the store's active funds
  /// accounts; the selection defaults to Cash Till.
  Widget _buildAccountPicker() {
    final storeId = ref.read(navigationProvider).lockedStoreId.value ??
        ref.read(authProvider).currentUser?.storeId;
    if (storeId == null) return const SizedBox.shrink();
    final accounts =
        ref.watch(fundsAccountsForStoreProvider(storeId)).valueOrNull ??
            const <FundsAccountData>[];
    if (accounts.isEmpty) return const SizedBox.shrink();
    final cashTill = accounts.where((a) => a.accountType == 'cash_till');
    final selected = _selectedFundsAccountId ??
        (cashTill.isNotEmpty ? cashTill.first.id : accounts.first.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: context.getRSize(20)),
        _sectionLabel('Receiving Account'),
        SizedBox(height: context.getRSize(12)),
        ...accounts.map((a) {
          final isSel = a.id == selected;
          final label = a.accountType == 'cash_till' ? 'Cash Till' : a.name;
          return GestureDetector(
            onTap: () => setState(() => _selectedFundsAccountId = a.id),
            child: Container(
              margin: EdgeInsets.only(bottom: context.getRSize(8)),
              padding: EdgeInsets.all(context.getRSize(14)),
              decoration: BoxDecoration(
                color:
                    isSel ? blueMain.withValues(alpha: 0.08) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSel ? blueMain : _border,
                  width: isSel ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isSel
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: context.getRSize(20),
                    color: isSel ? blueMain : _subtext,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w600,
                      color: _text,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  /// §14.1 — "Add wallet info to receipt" toggle. When ticked, the customer's
  /// resulting wallet balance is printed on the receipt (§15.1). Off by default.
  Widget _buildWalletInfoCheckbox() {
    final on = _addWalletInfoToReceipt;
    return GestureDetector(
      onTap: () =>
          setState(() => _addWalletInfoToReceipt = !_addWalletInfoToReceipt),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: on ? blueMain.withValues(alpha: 0.08) : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? blueMain : _border,
            width: on ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: context.getRSize(22),
              color: on ? blueMain : _subtext,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                'Add wallet info to receipt',
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletSubOptions() {
    final walletBalance = _walletBalanceFor(widget.customer?.id);
    final hasCredit = walletBalance > 0;

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
                () => setState(() {
                  _isWalletPayment = false;
                  _outstandingPaidConfirmed = false;
                }),
              ),
              SizedBox(width: context.getRSize(10)),
              _walletChip(
                'Pay from Wallet',
                _isWalletPayment,
                () => setState(() {
                  _isWalletPayment = true;
                  _outstandingPaidConfirmed = false;
                }),
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
                color: hasCredit
                    ? success.withValues(alpha: 0.08)
                    : danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasCredit
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
                      color: hasCredit ? success : danger,
                    ),
                  ),
                ],
              ),
            ),
            // §14.2 bug #4 — the credit only partially covers the order: apply
            // it and handle the rest. Ticking "outstanding paid" collects the
            // shortfall as cash (wallet → ₦0); leaving it unticked books the
            // shortfall as debt (wallet goes negative). The receiving account
            // picker for the cash renders below (gated on _isApplyCreditFlow).
            if (_isApplyCreditFlow) ...[
              SizedBox(height: context.getRSize(10)),
              _applyCreditRow(
                'Wallet credit applied',
                '−${formatCurrency(_walletCreditKobo / 100.0)}',
              ),
              _applyCreditRow(
                'Wallet after sale',
                formatCurrency(
                  _outstandingPaidConfirmed
                      ? 0
                      : (_currentCustomerWalletKobo - _totalKobo) / 100.0,
                ),
              ),
              _applyCreditRow(
                _outstandingPaidConfirmed
                    ? 'Outstanding to collect'
                    : 'Outstanding (added as debt)',
                formatCurrency(_outstandingAfterCreditKobo / 100.0),
                emphasise: true,
              ),
              SizedBox(height: context.getRSize(10)),
              _outstandingPaidCheckbox(),
              if (!_outstandingPaidConfirmed) ...[
                SizedBox(height: context.getRSize(6)),
                Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: context.getRSize(4)),
                  child: Text(
                    'Leave unticked to add the '
                    '${formatCurrency(_outstandingAfterCreditKobo / 100.0)} '
                    'outstanding to $_customerDisplayName\'s debt.',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ] else if (!hasCredit) ...[
              SizedBox(height: context.getRSize(6)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
                child: Text(
                  'No wallet credit available. Use Cash / Card or Partial '
                  'Payment instead.',
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

  /// A label/value line in the apply-credit breakdown (§14.2 bug #4).
  Widget _applyCreditRow(String label, String value, {bool emphasise = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: emphasise ? FontWeight.w800 : FontWeight.w600,
              color: emphasise ? _text : _subtext,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: context.getRFontSize(emphasise ? 15 : 13),
              fontWeight: emphasise ? FontWeight.w800 : FontWeight.w700,
              color: emphasise ? Theme.of(context).colorScheme.primary : _text,
            ),
          ),
        ],
      ),
    );
  }

  /// "Outstanding paid" confirmation for the apply-credit flow (§14.2 bug #4).
  Widget _outstandingPaidCheckbox() {
    final on = _outstandingPaidConfirmed;
    return GestureDetector(
      onTap: () => setState(
        () => _outstandingPaidConfirmed = !_outstandingPaidConfirmed,
      ),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(12)),
        decoration: BoxDecoration(
          color: on ? success.withValues(alpha: 0.08) : _surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on ? success : _border,
            width: on ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: context.getRSize(20),
              color: on ? success : _subtext,
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Text(
                'Outstanding ${formatCurrency(_outstandingAfterCreditKobo / 100.0)} '
                'was paid',
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
            ),
          ],
        ),
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
              _outstandingPaidConfirmed = false;
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
