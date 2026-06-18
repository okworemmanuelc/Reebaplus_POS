import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/logger.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CheckoutPage — shown after "Proceed to Checkout" in the cart.
// ─────────────────────────────────────────────────────────────────────────────

class CheckoutPage extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> cart;
  final double subtotal;
  // [total] is the GOODS total (subtotal − discounts − crate credit). The crate
  // deposit is no longer part of it — it's captured here per brand (§13.4 Ring 3)
  // and added to the payable on top.
  final double total;
  // §13.4 Ring 3 — per-brand crate lines from the cart, one map per manufacturer:
  // {manufacturerId, name, crates (double), rateKobo (int per crate)}. Drives the
  // editable, auto-filled deposit capture below.
  final List<Map<String, dynamic>> crateLines;
  final Customer? customer;
  final VoidCallback? onCheckoutSuccess;

  const CheckoutPage({
    super.key,
    required this.cart,
    required this.subtotal,
    required this.total,
    this.crateLines = const [],
    this.customer,
    this.onCheckoutSuccess,
  });

  @override
  ConsumerState<CheckoutPage> createState() => _CheckoutPageState();
}

/// Payment modes after the Full / Partial cards were removed (2026-06-05):
/// - cashTransfer → customer pays now (cash or transfer). The entered amount
///   drives the wallet — a shortfall is booked as debt, an excess tops it up.
/// - wallet       → charge the whole order to the wallet; available credit is
///   consumed and any shortfall becomes debt. No amount entered.
/// - credit       → nothing paid now; the whole total becomes debt. Registered
///   customers only ("Register as Credit Sale").
enum PayMode { cashTransfer, wallet, credit }

class _CheckoutPageState extends ConsumerState<CheckoutPage> {
  // Default to Cash / Transfer for everyone. In the post-2026-06-05 model a
  // wallet default would book a full-total debt on a thoughtless confirm when
  // the customer has no credit, so the cashier opts into Wallet / Credit Sale.
  PayMode _mode = PayMode.cashTransfer;
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
  String? _storeAddress;
  StreamSubscription<List<ManufacturerData>>? _manufacturersSub;
  StreamSubscription<StoreData?>? _activeStoreSub;
  late final Customer? _initialCustomer;

  // §13.4 Ring 3 — crate deposit PAID, per manufacturer (kobo). Auto-filled to
  // rate × crates from widget.crateLines, the cashier may reduce or zero each
  // brand. Only counts when the deposit applies (registered customer paying
  // Cash / Transfer — see _depositApplies); held as refundable money, never
  // revenue (§13.4). Keyed by manufacturerId → kobo.
  final Map<String, int> _depositByMfr = {};

  // Computed on confirm — passed to receipt

  double _amountPaid = 0;
  String _currentOrderId = '';

  /// Customer's wallet balance (Naira) AFTER the sale's two legs, captured at
  /// confirm time and shown on the receipt. Snapshotting avoids the pre-sale
  /// projection double-counting the just-posted dual-leg rows (§14.3, bug #5/#6).
  /// Null for walk-ins (no wallet).
  double? _receiptWalletBalance;

  /// §13.4 — the customer's empty-crate standing AFTER this sale (incl. the
  /// crates just issued), snapshotted at confirm for the receipt's wallet-info
  /// block: total crates owed, and total crates credited to them.
  int _receiptCratesOwed = 0;
  int _receiptCratesCredit = 0;

  late final CartService _cart;
  bool get _isWalkIn => _initialCustomer == null || _initialCustomer.isWalkIn;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;
  Color get _primary => Theme.of(context).colorScheme.primary;
  Color get _onPrimary => Theme.of(context).colorScheme.onPrimary;

  @override
  void initState() {
    super.initState();
    _initialCustomer = widget.customer;
    // §13.4 Ring 3 — each brand starts at ₦0; the cashier enters how much
    // deposit was actually paid (the section shows the full/expected deposit as
    // a reference + a per-brand "Use full" shortcut). A brand left at 0 is
    // "no deposit" → crate-track (settled via the crates tab at return).
    for (final line in widget.crateLines) {
      final mfrId = line['manufacturerId'] as String?;
      if (mfrId == null) continue;
      _depositByMfr[mfrId] = 0;
    }
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
      setState(() => _mode = PayMode.cashTransfer);
    }
  }

  Future<void> _loadManufacturers() async {
    final db = ref.read(databaseProvider);
    final nav = ref.read(navigationProvider);
    final auth = ref.read(authProvider);

    // §12.1: when "All Stores" is active (lockedStoreId null, an all-stores
    // viewer), sell from / resolve the user's first selectable store — matching
    // the POS grid's fallback — before the legacy currentUser.storeId fallback.
    final selectable = ref.read(selectableStoresProvider);
    final storeId =
        nav.lockedStoreId.value ??
        (selectable.isNotEmpty
            ? selectable.first.id
            : auth.currentUser?.storeId);

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
        setState(() => _storeAddress = receiptStoreAddress(w?.location));
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
    switch (_mode) {
      case PayMode.wallet:
        return 'Wallet Payment';
      case PayMode.credit:
        return 'Credit Sale';
      case PayMode.cashTransfer:
        if (_isWalkIn) return 'Cash / Transfer';
        final paidKobo = (_cashReceivedValue * 100).round();
        if (paidKobo <= 0) return 'Credit Sale';
        if (paidKobo < _totalKobo) return 'Partial Payment';
        return 'Cash / Transfer';
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

  /// Wallet balance (kobo) the customer would land on AFTER this sale in the
  /// current mode. Negative = debt. For Cash / Transfer the entered amount
  /// counts; Wallet / Credit Sale pay nothing now, so the full total is charged.
  int get _projectedWalletKobo {
    final paidKobo = _mode == PayMode.cashTransfer
        ? (_cashReceivedValue * 100).round()
        : 0;
    return _currentCustomerWalletKobo + paidKobo - _totalKobo;
  }

  /// True when this sale would book debt that breaches the customer's limit (or
  /// no limit is set). Drives the live warning; the same gate blocks on confirm.
  /// A fully-paid / overpaid Cash / Transfer never adds debt, so it's never
  /// gated even if the customer is already in debt.
  bool get _overDebtLimit {
    if (_isWalkIn) return false;
    final paidKobo = _mode == PayMode.cashTransfer
        ? (_cashReceivedValue * 100).round()
        : 0;
    if (paidKobo >= _totalKobo) return false;
    final projectedKobo = _projectedWalletKobo;
    if (projectedKobo >= 0) return false;
    final limitKobo = _currentCustomerWalletLimitKobo;
    return limitKobo <= 0 || projectedKobo < -limitKobo;
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

  int get _goodsTotalKobo => (widget.total * 100).round();

  /// True when the crate deposit is captured for this sale: a registered
  /// customer (walk-ins have no wallet to hold it, rule #14) paying Cash /
  /// Transfer (deposit is cash received now — a Wallet / Credit Sale hands over
  /// no fresh deposit, so the crates fall back to "owed / crate-track"), with
  /// crate brands in the cart.
  /// §13.4 / rule #13 — the selected business is Bar / Beer Distributor. The
  /// cart only passes crateLines for a crate business, but guard here too so the
  /// deposit section can never render for a non-crate type (defense in depth).
  bool get _isCrateBusiness {
    final bid = ref.read(authProvider).currentUser?.businessId;
    return isCrateBusiness(
      ref
          .read(localBusinessesProvider)
          .valueOrNull
          ?.where((b) => b.id == bid)
          .map((b) => b.type)
          .firstOrNull,
    );
  }

  bool get _depositApplies =>
      !_isWalkIn &&
      _mode == PayMode.cashTransfer &&
      _isCrateBusiness &&
      widget.crateLines.isNotEmpty;

  /// Total deposit PAID at checkout (kobo) — 0 unless [_depositApplies].
  int get _depositTotalKobo =>
      _depositApplies ? _depositByMfr.values.fold<int>(0, (s, v) => s + v) : 0;

  /// The full/expected deposit if every brand's crates were deposited in full
  /// (rate × crates summed). Shown as a reference; not added to the payable.
  int get _fullDepositKobo => widget.crateLines.fold<int>(0, (s, line) {
    final rateKobo = (line['rateKobo'] as int?) ?? 0;
    final crates = (line['crates'] as num?)?.toDouble() ?? 0;
    return s + (rateKobo * crates).round();
  });

  /// The payable total the customer settles = goods + the deposit held.
  int get _totalKobo => _goodsTotalKobo + _depositTotalKobo;

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
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
          _paymentConfirmed
              ? 'Receipt'
              : 'Checkout – ${formatCurrency(_totalKobo / 100)}',
          style: TextStyle(
            fontSize: context.getRFontSize(18),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
        ),
        centerTitle: false,
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
        context.getRSize(40) + context.deviceBottomPadding,
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
                if (_depositTotalKobo > 0)
                  _summaryRow('Crate Deposit', _depositTotalKobo / 100.0),
                Divider(height: 1, color: _border),
                _summaryRow(
                  'Total',
                  _totalKobo / 100.0,
                  bold: true,
                  accent: true,
                ),
              ],
            ),
          ),

          // ── Crate Deposit (editable, per brand) ───────────────────────
          if (_depositApplies) ...[
            SizedBox(height: context.getRSize(28)),
            _buildCrateDepositSection(),
          ],

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

          _buildPaymentMethods(),

          SizedBox(height: context.getRSize(32)),
          AppButton(
            text: 'Confirm Payment',
            variant: AppButtonVariant.primary,
            isLoading: _isProcessing,
            icon: FontAwesomeIcons.check.data,
            onPressed: _confirmPayment,
          ),
        ],
      ),
    );
  }

  // ── Crate deposit (editable, per brand) ──────────────────────────────────────
  /// §13.4 Ring 3 — the per-brand deposit capture. Each crate brand shows its
  /// auto-filled deposit (rate × crates); tap a row to change or zero it. The
  /// deposit is refundable money held for the customer (shown on the wallet as
  /// "Crate deposit held"), not income — it's settled when the empties come back.
  Widget _buildCrateDepositSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('Crate Deposit'),
        SizedBox(height: context.getRSize(6)),
        Text(
          'Refundable deposit held for the empties. Each brand starts at '
          '${formatCurrency(0)} — tap a brand to enter how much was paid.',
          style: TextStyle(fontSize: context.getRFontSize(12), color: _subtext),
        ),
        SizedBox(height: context.getRSize(12)),
        // Full/expected deposit reference (rate × crates across all brands).
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(14),
            vertical: context.getRSize(12),
          ),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'Full deposit if collected',
                  style: TextStyle(
                    fontSize: context.getRFontSize(13),
                    fontWeight: FontWeight.w700,
                    color: _text,
                  ),
                ),
              ),
              Text(
                formatCurrency(_fullDepositKobo / 100.0),
                style: TextStyle(
                  fontSize: context.getRFontSize(15),
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: [
              for (int i = 0; i < widget.crateLines.length; i++) ...[
                if (i > 0) Divider(height: 1, color: _border),
                _crateDepositRow(widget.crateLines[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _crateDepositRow(Map<String, dynamic> line) {
    final mfrId = line['manufacturerId'] as String;
    final name = (line['name'] as String?) ?? 'Brand';
    final crates = (line['crates'] as num?)?.toDouble() ?? 0;
    final rateKobo = (line['rateKobo'] as int?) ?? 0;
    final paidKobo = _depositByMfr[mfrId] ?? 0;
    final fullKobo = (rateKobo * crates).round();
    final isFull = paidKobo == fullKobo;
    final isNone = paidKobo == 0;
    final tag = isNone ? 'No deposit' : (isFull ? 'Full' : 'Part');

    return InkWell(
      onTap: () => _editBrandDeposit(mfrId, name, fullKobo),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(12),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(context.getRSize(8)),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                FontAwesomeIcons.beerMugEmpty.data,
                size: context.getRSize(14),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(14),
                      color: _text,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    '${crates.toStringAsFixed(crates == crates.roundToDouble() ? 0 : 1)} '
                    'crate${crates == 1 ? '' : 's'} · Full ${formatCurrency(fullKobo / 100.0)} · $tag',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              formatCurrency(paidKobo / 100.0),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: context.getRFontSize(14),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Icon(
              FontAwesomeIcons.penToSquare.data,
              size: context.getRSize(13),
              color: _subtext,
            ),
          ],
        ),
      ),
    );
  }

  /// Edit the deposit paid for one brand. Pre-fills the current value (blank =
  /// ₦0); the "Use full (₦X)" shortcut fills the full deposit; clearing/0 marks
  /// the brand "No deposit" (crate-track). Modal-style sheet (back / Save only).
  void _editBrandDeposit(String mfrId, String name, int fullKobo) {
    final ctrl = TextEditingController(
      text: (_depositByMfr[mfrId] ?? 0) == 0
          ? ''
          : ((_depositByMfr[mfrId] ?? 0) ~/ 100).toString(),
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return Padding(
          // nav-only inset (NOT deviceBottomInset). This sheet is shown from
          // Checkout, which is pushed on the TAB navigator under MainLayout —
          // whose Scaffold (resizeToAvoidBottomInset defaults true) already
          // resizes the tab body up by the keyboard, lifting this sheet above
          // it. Adding the keyboard again via deviceBottomInset double-counts it
          // and the sheet leaps up "like an extra keyboard". deviceBottomPadding
          // clears the system nav bar when the keyboard is down and collapses to
          // 0 when it's up (the resize covers that case).
          padding: EdgeInsets.fromLTRB(
            context.getRSize(24),
            context.getRSize(16),
            context.getRSize(24),
            context.deviceBottomPadding + context.getRSize(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              Text(
                'Deposit — $name',
                style: TextStyle(
                  fontSize: context.getRFontSize(18),
                  fontWeight: FontWeight.w800,
                  color: _text,
                ),
              ),
              SizedBox(height: context.getRSize(6)),
              Text(
                'Full deposit is ${formatCurrency(fullKobo / 100.0)}. '
                'Leave blank or 0 for no deposit (crates tracked instead).',
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  color: _subtext,
                ),
              ),
              SizedBox(height: context.getRSize(20)),
              AppInput(
                controller: ctrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
                autofocus: true,
                prefixText: '$activeCurrencySymbol ',
                hintText: '0',
              ),
              SizedBox(height: context.getRSize(12)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    ctrl.text = (fullKobo ~/ 100).toString();
                  },
                  icon: Icon(
                    FontAwesomeIcons.wandMagicSparkles.data,
                    size: context.getRSize(13),
                  ),
                  label: Text('Use full (${formatCurrency(fullKobo / 100.0)})'),
                ),
              ),
              SizedBox(height: context.getRSize(12)),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      text: 'Back',
                      variant: AppButtonVariant.ghost,
                      onPressed: () => Navigator.pop(sheetCtx),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      text: 'Save',
                      variant: AppButtonVariant.primary,
                      onPressed: () {
                        final val = (parseCurrency(ctrl.text) * 100).round();
                        setState(
                          () => _depositByMfr[mfrId] = val < 0 ? 0 : val,
                        );
                        Navigator.pop(sheetCtx);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
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
    } catch (e, st) {
      // §33.4: record the crash so it's visible across devices, then keep the
      // existing recoverable message — the sale flow must never blank-crash.
      CrashReporter.record(e, st, context: 'pos.checkout.verify_prices');
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

    // ── Validate by mode ──────────────────────────────────────────────────
    final paidKobo = _mode == PayMode.cashTransfer
        ? (_cashReceivedValue * 100).round()
        : 0;

    if (_isWalkIn) {
      // Walk-ins have no wallet (hard rule 14): Cash / Transfer only, paid in
      // full — any shortfall has nowhere to go. An empty amount means "paid the
      // full total" (one-tap), so only a positive entry NOT EQUAL TO the total is a
      // genuine over/underpayment to block.
      if (_mode != PayMode.cashTransfer ||
          (paidKobo > 0 && paidKobo != _totalKobo)) {
        AppNotification.showError(
          context,
          'Walk-in customers must pay exactly the cart total.',
        );
        return;
      }
    } else {
      // Cash / Transfer needs an amount entered. To book the whole total as
      // debt, the cashier picks "Register as Credit Sale" instead.
      if (_mode == PayMode.cashTransfer && paidKobo <= 0) {
        AppNotification.showError(
          context,
          'Enter the amount paid, or choose Register as Credit Sale.',
        );
        return;
      }

      // §13.4 — the crate deposit is held cash: the cashier can't book a held
      // deposit they didn't receive. So the amount paid must at least cover the
      // deposit; the remainder applies to goods (and may go to debt). To skip the
      // deposit, the cashier zeroes the brand(s) above (→ crates tracked instead).
      if (_depositTotalKobo > 0 && paidKobo < _depositTotalKobo) {
        AppNotification.showError(
          context,
          'Amount paid must cover the crate deposit of '
          '${formatCurrency(_depositTotalKobo / 100.0)}. '
          'Reduce the deposit or collect more.',
        );
        return;
      }

      // Debt-limit gate. Only a sale that ADDS debt is gated — a fully-paid or
      // overpaid Cash / Transfer never is (even for a customer already in debt).
      // Balance + limit are read live (no awaited DB round-trip) so the
      // over-limit message always flashes (#7).
      if (paidKobo < _totalKobo) {
        final projectedKobo =
            _currentCustomerWalletKobo + paidKobo - _totalKobo;
        if (projectedKobo < 0) {
          final customer = _initialCustomer!;
          final limitKobo = _currentCustomerWalletLimitKobo;
          if (limitKobo <= 0) {
            AppNotification.showError(
              context,
              '${customer.name} has no debt limit set. Set a debt limit in the '
              'customer profile before booking this debt.',
            );
            return;
          }
          if (projectedKobo < -limitKobo) {
            final overByKobo = (-projectedKobo) - limitKobo;
            AppNotification.showError(
              context,
              'This sale exceeds ${customer.name}\'s debt limit of '
              '${formatCurrency(limitKobo / 100.0)}. '
              'Over limit by ${formatCurrency(overByKobo / 100.0)}.',
            );
            return;
          }
        }
      }
    }

    setState(() => _isProcessing = true);

    try {
      final totalKobo = _totalKobo;
      // Walk-ins pay exactly the total (no wallet to absorb over/under). For a
      // registered customer the entered amount drives the wallet legs:
      // createOrder posts a debit of the total + a credit of amountPaid, so the
      // net (paid − total) books a shortfall as debt or tops the wallet up on an
      // excess (daos.dart). Wallet / Credit Sale pay nothing now (amountPaid 0):
      // the full total debits the wallet, going into debt if credit can't cover.
      final amountPaidKobo = _isWalkIn ? totalKobo : paidKobo;
      final paymentSubType = _mode == PayMode.wallet ? 'wallet' : 'cash';

      // Snapshot the wallet balance BEFORE the legs post so the receipt shows
      // the true post-sale net (old + paid − total) instead of the pre-sale
      // projection re-applied on top of the just-written rows (#5/#6).
      final oldWalletKobo = _currentCustomerWalletKobo;

      // ── Call atomic transaction ──────────────────────────────────────
      final auth = ref.read(authProvider);
      final nav = ref.read(navigationProvider);
      // §12.1 "All Stores" fallback → first selectable store (matches the POS
      // grid), then the legacy currentUser.storeId fallback.
      final selectable = ref.read(selectableStoresProvider);
      final storeId =
          nav.lockedStoreId.value ??
          (selectable.isNotEmpty
              ? selectable.first.id
              : auth.currentUser?.storeId);

      // Ensure store address is resolved before proceeding to receipt
      if (_storeAddress == null && storeId != null) {
        final db = ref.read(databaseProvider);
        final w = await (db.select(
          db.stores,
        )..where((t) => t.id.equals(storeId))).getSingleOrNull();
        if (mounted) {
          setState(() => _storeAddress = receiptStoreAddress(w?.location));
        }
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
            // §13.4 Ring 3/6 — the per-brand deposit captured above. The total
            // (sum) tags the order as non-revenue; the map drives createOrder's
            // held-deposit wallet leg + order_crate_lines + issued gating. Both
            // are 0/empty unless the deposit applies (registered + Cash/Transfer).
            crateDepositPaidKobo: _depositTotalKobo,
            crateDepositPaidByManufacturer: _depositApplies
                ? Map<String, int>.from(_depositByMfr)
                : const {},
            discountKobo: widget.cart.fold<int>(
              0,
              (s, i) => s + ((i['discountKobo'] as int?) ?? 0),
            ),
            // 'wallet' debits the whole total from the wallet (no cash lands);
            // 'cash' covers Cash / Transfer and Credit Sale — the entered amount
            // (0 for a credit sale) credits the wallet, netting against the total.
            paymentSubType: paymentSubType,
          );

      // §13.4 — snapshot the customer's empty-crate standing AFTER the sale
      // (createOrder has just issued this sale's crates) for the receipt's
      // wallet-info block. Registered customers only (walk-ins hold no crates).
      int cratesOwed = 0, cratesCredit = 0;
      final crateCustomerId = _initialCustomer?.id;
      if (!_isWalkIn && crateCustomerId != null) {
        try {
          final balances = await ref
              .read(databaseProvider)
              .customersDao
              .watchCrateBalancesWithGroups(crateCustomerId)
              .first;
          for (final b in balances) {
            if (b.balance > 0) {
              cratesOwed += b.balance;
            } else if (b.balance < 0) {
              cratesCredit += -b.balance;
            }
          }
        } catch (_) {
          // Non-fatal — the receipt just omits the crate lines if this fails.
        }
      }

      // ── Success Flow ────────────────────────────────────────────────
      if (mounted) {
        setState(() {
          _amountPaid = amountPaidKobo / 100.0;
          // True post-sale wallet net = old + credit(paid) − debit(total).
          // Walk-ins have no wallet (§14.3).
          _receiptWalletBalance = _isWalkIn
              ? null
              : (oldWalletKobo + amountPaidKobo - totalKobo) / 100.0;
          _receiptCratesOwed = cratesOwed;
          _receiptCratesCredit = cratesCredit;
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
    } catch (e, st) {
      // §33.4: the most critical action in the app — record the crash for
      // cross-device review, then keep the existing recoverable message.
      // (The cloud RPC rolls back its own transaction on rejection; see
      // _compensateRejectedSale — nothing to undo locally here.)
      CrashReporter.record(e, st, context: 'pos.checkout.confirm');
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
          child: _isPrinting ? _buildPrintingBanner() : const SizedBox.shrink(),
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
                crateDeposit: _depositTotalKobo / 100.0,
                total: _totalKobo / 100.0,
                paymentMethod: _paymentLabel,
                customerName: _customerDisplayName,
                customerAddress: _initialCustomer?.addressText ?? 'N/A',
                customerPhone: _initialCustomer?.phone,
                cashReceived: _amountPaid,
                walletBalance: _receiptWalletBalance,
                showWalletInfo: !_isWalkIn && _addWalletInfoToReceipt,
                cratesOwed: _receiptCratesOwed,
                cratesCredit: _receiptCratesCredit,
                riderName: 'Pick-up Order',
                manufacturerNames: _manufacturerNames,
                storeAddress: _storeAddress,
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
      color: _primary,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(20),
        vertical: context.getRSize(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FontAwesomeIcons.print.data,
            size: context.getRSize(16),
            color: _onPrimary,
          ),
          SizedBox(width: context.getRSize(10)),
          Text(
            'Printing receipt…',
            style: TextStyle(
              color: _onPrimary,
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
        context.getRSize(32) + context.deviceBottomPadding,
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
                  FontAwesomeIcons.print.data,
                  Theme.of(context).colorScheme.primary,
                  _printReceipt,
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _receiptButton(
                  'Share Receipt',
                  FontAwesomeIcons.shareNodes.data,
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
        crateDeposit: _depositTotalKobo / 100.0,
        total: _totalKobo / 100.0,
        paymentMethod: _paymentLabel,
        customerName: _customerDisplayName,
        customerAddress: widget.customer?.addressText,
        customerPhone: widget.customer?.phone,
        cashReceived: _amountPaid,
        // Use the post-sale snapshot (set at confirm) — the live provider has
        // already updated, so recomputing here would double-count the legs.
        walletBalance: _receiptWalletBalance,
        showWalletInfo: !_isWalkIn && _addWalletInfoToReceipt,
        cratesOwed: _receiptCratesOwed,
        cratesCredit: _receiptCratesCredit,
        riderName: 'Pick-up Order',
        storeAddress: _storeAddress,
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
          color: on ? _primary.withValues(alpha: 0.08) : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? _primary : _border,
            width: on ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.check_box : Icons.check_box_outline_blank,
              size: context.getRSize(22),
              color: on ? _primary : _subtext,
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

  // ── Payment methods (post-2026-06-05) ──────────────────────────────────────
  // Two method chips (Cash / Transfer, Pay from Wallet) plus the retained
  // "Register as Credit Sale" card. Walk-ins have no wallet (hard rule 14) — they
  // only ever pay Cash / Transfer in full, so they see neither the wallet chip
  // nor the credit-sale card.
  Widget _buildPaymentMethods() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _methodChip(
                'Cash / Transfer',
                FontAwesomeIcons.moneyBill.data,
                _mode == PayMode.cashTransfer,
                () => setState(() => _mode = PayMode.cashTransfer),
              ),
            ),
            if (!_isWalkIn) ...[
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: _methodChip(
                  'Pay from Wallet',
                  FontAwesomeIcons.wallet.data,
                  _mode == PayMode.wallet,
                  () => setState(() => _mode = PayMode.wallet),
                ),
              ),
            ],
          ],
        ),

        // Cash / Transfer → amount input + live resulting-balance preview.
        if (_mode == PayMode.cashTransfer) _buildCashTransferInput(),

        // Pay from Wallet → balance + resulting debt preview (no input).
        if (_mode == PayMode.wallet) _buildWalletPreview(),

        // Register as Credit Sale — retained card. Registered customers only.
        if (!_isWalkIn) ...[
          SizedBox(height: context.getRSize(16)),
          _creditSaleCard(),
          if (_mode == PayMode.credit) ...[
            SizedBox(height: context.getRSize(10)),
            _buildCreditPreview(),
          ],
        ],

        // §14.1 — "Add wallet info to receipt" (off by default, registered only).
        if (!_isWalkIn) ...[
          SizedBox(height: context.getRSize(20)),
          _buildWalletInfoCheckbox(),
        ],
      ],
    );
  }

  /// A payment-method chip (Cash / Transfer, Pay from Wallet).
  Widget _methodChip(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(12),
        ),
        decoration: BoxDecoration(
          color: selected ? _primary.withValues(alpha: 0.10) : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? _primary : _border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: context.getRSize(16),
              color: selected ? _primary : _subtext,
            ),
            SizedBox(width: context.getRSize(8)),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.getRFontSize(13),
                  fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                  color: selected ? _primary : _subtext,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Cash / Transfer: the amount-paid field plus the live resulting-balance
  /// preview (registered) or a pay-in-full reminder (walk-in).
  Widget _buildCashTransferInput() {
    int suggestedKobo = _totalKobo;
    if (!_isWalkIn && _currentCustomerWalletKobo > 0) {
      suggestedKobo = _totalKobo - _currentCustomerWalletKobo;
      if (suggestedKobo < _depositTotalKobo) {
        suggestedKobo = _depositTotalKobo;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: context.getRSize(16)),
        AppInput(
          controller: _cashReceivedCtrl,
          labelText: 'Amount Paid',
          hintText: '₦ Enter amount paid',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [CurrencyInputFormatter()],
          onChanged: (v) => setState(() {}),
          suffixIcon: TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(12)),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              final val = suggestedKobo / 100.0;
              _cashReceivedCtrl.text = val == val.roundToDouble()
                  ? val.toInt().toString()
                  : val.toStringAsFixed(2);
              setState(() {});
            },
            child: Text(
              'Auto-fill ${formatCurrency(suggestedKobo / 100.0)}',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
        if (_isWalkIn) ...[
          SizedBox(height: context.getRSize(8)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
            child: Text(
              'Walk-in customers must pay the full ${formatCurrency(widget.total)}.',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: _subtext,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ] else ...[
          SizedBox(height: context.getRSize(12)),
          _resultPreview(),
        ],
      ],
    );
  }

  /// Registered Cash / Transfer preview: resulting wallet balance + a hint
  /// (shortfall → debt, excess → wallet, or fully paid) + a debt-limit warning.
  Widget _resultPreview() {
    final projectedKobo = _projectedWalletKobo; // negative = debt
    final projected = projectedKobo / 100.0;
    final isDebt = projectedKobo < 0;
    final diffKobo = (_cashReceivedValue * 100).round() - _totalKobo;

    String hint;
    if (diffKobo < 0) {
      hint =
          'Shortfall ${formatCurrency(-diffKobo / 100.0)} added to '
          '$_customerDisplayName\'s wallet as debt.';
    } else if (diffKobo > 0) {
      hint =
          'Excess ${formatCurrency(diffKobo / 100.0)} added to '
          '$_customerDisplayName\'s wallet.';
    } else {
      hint = 'Fully paid — no change to the wallet.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _previewBox(
          'Resulting Wallet Balance',
          projected,
          isDebt ? danger : (projected > 0 ? success : _text),
          isDebt ? ' (debt)' : (projected > 0 ? ' (credit)' : ''),
        ),
        SizedBox(height: context.getRSize(6)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
          child: Text(
            hint,
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              color: _subtext,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        if (_overDebtLimit)
          _debtLimitWarning(_currentCustomerWalletLimitKobo, projectedKobo),
      ],
    );
  }

  /// Pay from Wallet preview: current balance, the balance after this sale, a
  /// short explanation, and a debt-limit warning if the credit can't cover it.
  Widget _buildWalletPreview() {
    final balance = _currentCustomerWallet;
    final projectedKobo = _projectedWalletKobo; // current − total
    final projected = projectedKobo / 100.0;
    final isDebt = projectedKobo < 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: context.getRSize(12)),
        _previewBox(
          'Wallet Balance',
          balance,
          balance < 0 ? danger : (balance > 0 ? success : _text),
          balance < 0 ? ' (debt)' : (balance > 0 ? ' (credit)' : ''),
        ),
        SizedBox(height: context.getRSize(8)),
        _previewBox(
          'After This Sale',
          projected,
          isDebt ? danger : (projected > 0 ? success : _text),
          isDebt ? ' (debt)' : (projected > 0 ? ' (credit)' : ''),
        ),
        SizedBox(height: context.getRSize(6)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
          child: Text(
            isDebt
                ? 'Wallet credit can\'t cover the order — the shortfall is added '
                      'as debt.'
                : 'The order is charged to the wallet credit.',
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              color: _subtext,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        if (_overDebtLimit)
          _debtLimitWarning(_currentCustomerWalletLimitKobo, projectedKobo),
      ],
    );
  }

  /// Credit Sale preview: the resulting (debt) balance + debt-limit warning.
  Widget _buildCreditPreview() {
    final projectedKobo = _projectedWalletKobo; // current − total
    final projected = projectedKobo / 100.0;
    final isDebt = projectedKobo < 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _previewBox(
          'Resulting Wallet Balance',
          projected,
          isDebt ? danger : (projected > 0 ? success : _text),
          isDebt ? ' (debt)' : (projected > 0 ? ' (credit)' : ''),
        ),
        if (_overDebtLimit)
          _debtLimitWarning(_currentCustomerWalletLimitKobo, projectedKobo),
      ],
    );
  }

  /// A label / value box used by the payment previews.
  Widget _previewBox(
    String label,
    double value,
    Color valueColor,
    String suffix,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w700,
                color: _text,
              ),
            ),
          ),
          Text(
            '${formatCurrency(value)}$suffix',
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Red warning shown when a debt-adding sale breaches the customer's limit
  /// (or none is set). The same condition blocks on Confirm Payment.
  Widget _debtLimitWarning(int limitKobo, int projectedKobo) {
    final msg = limitKobo <= 0
        ? '$_customerDisplayName has no debt limit set — set one before booking '
              'this debt.'
        : 'Over $_customerDisplayName\'s debt limit of '
              '${formatCurrency(limitKobo / 100.0)} by '
              '${formatCurrency(((-projectedKobo) - limitKobo) / 100.0)}.';
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(8)),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(12)),
        decoration: BoxDecoration(
          color: danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(
              FontAwesomeIcons.triangleExclamation.data,
              size: context.getRSize(14),
              color: danger,
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Text(
                msg,
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w600,
                  color: danger,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "Register as Credit Sale" — the one retained payment card (registered
  /// customers only). Nothing is paid now; the whole total becomes wallet debt.
  Widget _creditSaleCard() {
    final active = _mode == PayMode.credit;
    return GestureDetector(
      onTap: () => setState(() => _mode = PayMode.credit),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? _primary : _border,
            width: active ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(42),
              height: context.getRSize(42),
              decoration: BoxDecoration(
                color: (active ? _primary : _subtext).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FontAwesomeIcons.fileInvoiceDollar.data,
                size: context.getRSize(18),
                color: active ? _primary : _subtext,
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Register as Credit Sale',
                    style: TextStyle(
                      fontWeight: active ? FontWeight.bold : FontWeight.w600,
                      fontSize: context.getRFontSize(14),
                      color: active ? _primary : _text,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    'Nothing paid now — full amount added to the wallet as debt',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: context.getRSize(22),
              height: context.getRSize(22),
              decoration: BoxDecoration(
                color: active ? _primary : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? _primary : _border,
                  width: 2,
                ),
              ),
              child: active
                  ? Icon(
                      Icons.check,
                      size: context.getRSize(14),
                      color: _onPrimary,
                    )
                  : null,
            ),
          ],
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
        ? productIconFromCodePoint(rawIcon)
        : FontAwesomeIcons.box.data;

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
              color: accent ? _primary : _text,
            ),
          ),
        ],
      ),
    );
  }
}
