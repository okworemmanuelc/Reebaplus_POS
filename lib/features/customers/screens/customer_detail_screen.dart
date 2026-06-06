import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show innerJoin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:flutter/services.dart';
import 'package:reebaplus_pos/core/widgets/amber_button.dart';
import 'package:reebaplus_pos/core/widgets/status_badge.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/edit_customer_sheet.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

class CustomerDetailScreen extends ConsumerStatefulWidget {
  final Customer? customer;

  const CustomerDetailScreen({super.key, this.customer});

  @override
  ConsumerState<CustomerDetailScreen> createState() =>
      _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen> {
  bool _contentReady = false;
  final ScreenshotController _screenshotCtrl = ScreenshotController();

  CustomerData? _customerData;
  int _walletBalance = 0;
  int _depositsHeld = 0; // §13.4 — refundable crate deposit held (kobo)
  List<WalletTransactionData> _walletHistory = [];
  String _selectedPeriod = 'To Date'; // §30.11 canonical chip set
  List<OrderData> _orders = [];
  List<CrateBalanceEntry> _crateBalances = [];

  StreamSubscription<CustomerData?>? _customerSub;
  StreamSubscription<int>? _balanceSub;
  StreamSubscription<int>? _depositsHeldSub;
  StreamSubscription<List<WalletTransactionData>>? _historySub;
  StreamSubscription<List<OrderData>>? _ordersSub;
  StreamSubscription<List<CrateBalanceEntry>>? _cratesSub;

  @override
  void initState() {
    super.initState();
    // Initial balance comes from the watchWalletBalance stream below.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  void _loadData() {
    if (!mounted) return;
    final id = widget.customer?.id;
    if (id == null || id.isEmpty || id == Customer.walkInId) {
      setState(() => _contentReady = true);
      return;
    }

    final db = ref.read(databaseProvider);

    _customerSub = db.customersDao.watchCustomerById(id).listen((data) {
      if (mounted) setState(() => _customerData = data);
    });

    _balanceSub = db.customersDao.watchWalletBalance(id).listen((bal) {
      if (mounted) setState(() => _walletBalance = bal);
    });

    _depositsHeldSub =
        db.customersDao.watchWalletDepositsHeldKobo(id).listen((held) {
      if (mounted) setState(() => _depositsHeld = held);
    });

    _historySub = db.customersDao.watchWalletHistory(id).listen((hist) {
      if (mounted) setState(() => _walletHistory = hist);
    });

    _ordersSub = db.ordersDao.watchOrdersByCustomer(id).listen((orders) {
      if (mounted) setState(() => _orders = orders);
    });

    _cratesSub = db.customersDao.watchCrateBalancesWithGroups(id).listen((
      crates,
    ) {
      if (mounted) setState(() => _crateBalances = crates);
    });

    _contentReady = true;
  }

  @override
  void dispose() {
    _customerSub?.cancel();
    _balanceSub?.cancel();
    _depositsHeldSub?.cancel();
    _historySub?.cancel();
    _ordersSub?.cancel();
    _cratesSub?.cancel();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _name => _customerData?.name ?? widget.customer?.name ?? '?';
  String get _phone => _customerData?.phone ?? widget.customer?.phone ?? '';
  String get _address =>
      _customerData?.address ?? widget.customer?.addressText ?? '';
  String get _groupName =>
      _customerData?.priceTier ??
      widget.customer?.priceTier.name ??
      'retailer';
  DateTime get _joinedAt =>
      _customerData?.createdAt ?? widget.customer?.createdAt ?? DateTime.now();
  int get _limitKobo =>
      _customerData?.walletLimitKobo ?? widget.customer?.walletLimitKobo ?? 0;
  String? get _customerId => widget.customer?.id;

  /// Period labels this viewer may choose (§19.2/§30.11 — roles below Manager
  /// are capped to Today/This Week/This Month).
  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  /// [_selectedPeriod] clamped into [_periodOptions], so the dropdown value and
  /// the filter agree for capped viewers (default is "To Date", out of their set).
  String get _effectivePeriod => _periodOptions.contains(_selectedPeriod)
      ? _selectedPeriod
      : _periodOptions.last;

  List<WalletTransactionData> get _filteredHistory {
    final window = datePeriodFromLabel(_effectivePeriod);
    return _walletHistory
        .where((txn) => window.includes(txn.createdAt))
        .toList();
  }

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  String _friendlyRefType(String ref) {
    switch (ref) {
      case 'topup_cash':
        return 'Cash top-up';
      case 'topup_transfer':
        return 'Transfer top-up';
      case 'order_payment':
        return 'Order charge';
      case 'cash_received':
        return 'Cash received';
      case 'refund':
        return 'Refund';
      case 'reward':
        return 'Reward';
      case 'fee':
        return 'Fee';
      // §13.4 crate-deposit family — friendly labels so the history never shows
      // raw snake_case (e.g. "crate_deposit"). The held figure is also surfaced
      // on its own "Crate deposit held" line above.
      case 'crate_deposit':
        return 'Crate deposit (held)';
      case 'crate_deposit_refunded':
        return 'Deposit refunded';
      case 'crate_deposit_forfeited':
        return 'Deposit forfeited';
      case 'crate_refund':
        return 'Crate refund';
      case 'adjustment':
        return 'Adjustment';
      default:
        return ref;
    }
  }

  BadgeVariant _orderStatusVariant(String status) {
    switch (status) {
      case 'completed':
        return BadgeVariant.green;
      case 'cancelled':
      case 'refunded':
        return BadgeVariant.red;
      default:
        return BadgeVariant.amber;
    }
  }

  // ── Sheets ─────────────────────────────────────────────────────────────────

  void _showAddFundsSheet() {
    final id = _customerId;
    if (id == null) return;

    // §18 Add Funds — needs the acting staff to attribute the wallet top-up.
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Could not start a top-up yet — no active session.',
      );
      return;
    }

    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String selectedMethod = 'cash'; // 'cash' | 'transfer'

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Consumer(
          builder: (ctx, sheetRef, _) {
            final accent = Theme.of(ctx).colorScheme.primary;
            final onSurface = Theme.of(ctx).colorScheme.onSurface;

            return _SheetContainer(
              scrollController: ScrollController(),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SheetHandle(),
                    Text(
                      'Add Funds',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: ctx.getRFontSize(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(4)),
                    Text(
                      'Top up $_name\'s wallet',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: ctx.getRFontSize(13),
                        color: onSurface.withAlpha(128),
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(24)),
                    _SheetField(
                      controller: amountCtrl,
                      label: 'Amount (₦)',
                      keyboard:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [CurrencyInputFormatter()],
                      validator: (v) {
                        final n = parseCurrency(v ?? '');
                        if (n <= 0) return 'Enter a valid amount';
                        return null;
                      },
                    ),
                    SizedBox(height: ctx.getRSize(16)),
                    Text(
                      'Payment method',
                      style: TextStyle(
                        fontSize: ctx.getRFontSize(13),
                        fontWeight: FontWeight.w600,
                        color: onSurface.withAlpha(178),
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(8)),
                    ...[
                      ('cash', 'Cash'),
                      ('transfer', 'Bank Transfer'),
                    ].map((opt) {
                      final isSel = selectedMethod == opt.$1;
                      return GestureDetector(
                        onTap: () =>
                            setSheetState(() => selectedMethod = opt.$1),
                        child: Container(
                          margin: EdgeInsets.only(bottom: ctx.getRSize(8)),
                          padding: EdgeInsets.all(ctx.getRSize(14)),
                          decoration: BoxDecoration(
                            color: isSel
                                ? accent.withValues(alpha: 0.08)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSel ? accent : onSurface.withAlpha(40),
                              width: isSel ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSel
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: ctx.getRSize(20),
                                color: isSel
                                    ? accent
                                    : onSurface.withAlpha(128),
                              ),
                              SizedBox(width: ctx.getRSize(12)),
                              Text(
                                opt.$2,
                                style: TextStyle(
                                  fontSize: ctx.getRFontSize(14),
                                  fontWeight: FontWeight.w600,
                                  color: onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    SizedBox(height: ctx.getRSize(16)),
                    _SheetField(
                      controller: noteCtrl,
                      label: 'Note (optional)',
                      keyboard: TextInputType.text,
                    ),
                    SizedBox(height: ctx.getRSize(24)),
                    AmberButton(
                      label: 'Add Funds',
                      icon: Icons.add,
                      onPressed: () async {
                              if (!formKey.currentState!.validate()) return;
                              final amount = parseCurrency(amountCtrl.text);
                              final note = noteCtrl.text.trim();
                              final method = selectedMethod;
                              final messenger = ScaffoldMessenger.of(context);
                              // Defense-in-depth write-boundary re-check (§10.2.1):
                              // the Add Funds button is already render-gated on
                              // `customers.wallet.update`, but re-check the
                              // effective permission before moving money so a
                              // revoked override is honored at the action too.
                              if (!ref
                                  .read(currentUserPermissionsProvider)
                                  .contains('customers.wallet.update')) {
                                Navigator.pop(ctx);
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'You don\'t have permission to do that.'),
                                  ),
                                );
                                return;
                              }
                              Navigator.pop(ctx);
                              try {
                                await ref
                                    .read(customerServiceProvider)
                                    .topUpWallet(
                                      customerId: id,
                                      amountKobo: (amount * 100).round(),
                                      method: method,
                                      staffId: staffId,
                                      note: note.isEmpty ? null : note,
                                    );
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '₦${amount.toStringAsFixed(0)} added to wallet',
                                    ),
                                    backgroundColor: success,
                                  ),
                                );
                              } catch (_) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Could not add funds'),
                                  ),
                                );
                              }
                            },
                    ),
                    SizedBox(
                      height: ctx.deviceBottomInset + ctx.getRSize(16),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // §18.3 Refund Cash (CEO/Manager only — render-gated on
  // `customers.wallet.withdraw`). Pays the customer back, in cash, money the
  // business holds for them: their held crate deposit and/or positive spendable
  // wallet credit. The amount is capped at what's available so a debt can never
  // be refunded; the service draws the deposit first, then credit.
  void _showRefundCashSheet() async {
    final id = _customerId;
    if (id == null) return;

    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Could not start a refund yet — no active session.',
      );
      return;
    }

    // What can actually be refunded: held deposit + positive spendable credit.
    final db = ref.read(databaseProvider);
    final heldKobo = await db.walletTransactionsDao.getDepositsHeldKobo(id);
    final spendableKobo = await db.walletTransactionsDao.getBalanceKobo(id);
    final depositAvail = heldKobo > 0 ? heldKobo : 0;
    final creditAvail = spendableKobo > 0 ? spendableKobo : 0;
    final availableKobo = depositAvail + creditAvail;
    // When the wallet is in DEBT, the held deposit is refunded TO THE WALLET
    // (reduces the debt) — no cash option (user, 2026-06-05). Spendable credit
    // is 0 when in debt, so only the deposit is refundable here.
    final inDebt = spendableKobo < 0;
    if (!mounted) return;
    if (availableKobo <= 0) {
      AppNotification.showInfo(
        context,
        'Nothing to refund — this customer has no wallet credit or held '
        'deposit. (Refunds can\'t be drawn from a debt.)',
      );
      return;
    }

    final amountCtrl = TextEditingController(
      text: (availableKobo / 100)
          .toStringAsFixed(availableKobo % 100 == 0 ? 0 : 2),
    );
    final noteCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String selectedMethod = 'cash'; // 'cash' | 'transfer' | 'pos' | 'other'

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Consumer(
          builder: (ctx, sheetRef, _) {
            final accent = Theme.of(ctx).colorScheme.primary;
            final onSurface = Theme.of(ctx).colorScheme.onSurface;

            return _SheetContainer(
              scrollController: ScrollController(),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SheetHandle(),
                    Text(
                      inDebt ? 'Refund Deposit' : 'Refund Cash',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: ctx.getRFontSize(18),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(4)),
                    Text(
                      inDebt
                          ? 'Refund to $_name\'s wallet — reduces what they owe'
                          : 'Pay $_name back in cash',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: ctx.getRFontSize(13),
                        color: onSurface.withAlpha(128),
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(20)),
                    // What's available, broken down.
                    Container(
                      padding: EdgeInsets.all(ctx.getRSize(14)),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: accent.withAlpha(40)),
                      ),
                      child: Column(
                        children: [
                          if (creditAvail > 0)
                            _refundAvailRow(
                                ctx, 'Wallet credit', creditAvail, onSurface),
                          if (depositAvail > 0)
                            _refundAvailRow(ctx, 'Crate deposit held',
                                depositAvail, onSurface),
                          if (creditAvail > 0 && depositAvail > 0) ...[
                            Divider(height: ctx.getRSize(16)),
                            _refundAvailRow(
                                ctx, 'Available', availableKobo, onSurface,
                                bold: true),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(height: ctx.getRSize(20)),
                    _SheetField(
                      controller: amountCtrl,
                      label: 'Amount to refund (₦)',
                      keyboard:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [CurrencyInputFormatter()],
                      validator: (v) {
                        final n = parseCurrency(v ?? '');
                        if (n <= 0) return 'Enter a valid amount';
                        if ((n * 100).round() > availableKobo) {
                          return 'Max ${formatCurrency(availableKobo / 100)}';
                        }
                        return null;
                      },
                    ),
                    if (!inDebt) ...[
                      SizedBox(height: ctx.getRSize(16)),
                      Text(
                        'Refund method',
                        style: TextStyle(
                          fontSize: ctx.getRFontSize(13),
                          fontWeight: FontWeight.w600,
                          color: onSurface.withAlpha(178),
                        ),
                      ),
                      SizedBox(height: ctx.getRSize(8)),
                      ...[
                        ('cash', 'Cash'),
                        ('transfer', 'Bank Transfer'),
                        ('pos', 'POS card'),
                        ('other', 'Other'),
                      ].map((opt) {
                        final isSel = selectedMethod == opt.$1;
                        return GestureDetector(
                          onTap: () =>
                              setSheetState(() => selectedMethod = opt.$1),
                          child: Container(
                            margin: EdgeInsets.only(bottom: ctx.getRSize(8)),
                            padding: EdgeInsets.all(ctx.getRSize(14)),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? accent.withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSel ? accent : onSurface.withAlpha(40),
                                width: isSel ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSel
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: ctx.getRSize(20),
                                  color: isSel
                                      ? accent
                                      : onSurface.withAlpha(128),
                                ),
                                SizedBox(width: ctx.getRSize(12)),
                                Text(
                                  opt.$2,
                                  style: TextStyle(
                                    fontSize: ctx.getRFontSize(14),
                                    fontWeight: FontWeight.w600,
                                    color: onSurface,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ] else ...[
                      SizedBox(height: ctx.getRSize(12)),
                      Container(
                        padding: EdgeInsets.all(ctx.getRSize(12)),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              FontAwesomeIcons.circleInfo,
                              size: ctx.getRSize(14),
                              color: accent,
                            ),
                            SizedBox(width: ctx.getRSize(10)),
                            Expanded(
                              child: Text(
                                'This customer is in debt, so the deposit is '
                                'added to their wallet to reduce what they owe — '
                                'no cash is paid out.',
                                style: TextStyle(
                                  fontSize: ctx.getRFontSize(12),
                                  color: onSurface.withAlpha(200),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    SizedBox(height: ctx.getRSize(16)),
                    _SheetField(
                      controller: noteCtrl,
                      label: 'Note (optional)',
                      keyboard: TextInputType.text,
                    ),
                    SizedBox(height: ctx.getRSize(24)),
                    AmberButton(
                      label: inDebt ? 'Refund to Wallet' : 'Refund Cash',
                      icon: FontAwesomeIcons.moneyBillTransfer,
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;
                        final amount = parseCurrency(amountCtrl.text);
                        final amountKobo = (amount * 100).round();
                        final note = noteCtrl.text.trim();
                        final method = selectedMethod;
                        final messenger = ScaffoldMessenger.of(context);
                        // Defense-in-depth write-boundary re-check (§10.2.1):
                        // the button is render-gated on
                        // `customers.wallet.withdraw`, but re-check the effective
                        // permission before moving money so a revoked override is
                        // honored at the action too.
                        if (!ref
                            .read(currentUserPermissionsProvider)
                            .contains('customers.wallet.withdraw')) {
                          Navigator.pop(ctx);
                          messenger.showSnackBar(
                            const SnackBar(
                              content:
                                  Text('You don\'t have permission to do that.'),
                            ),
                          );
                          return;
                        }
                        Navigator.pop(ctx);
                        try {
                          final refundedKobo = await ref
                              .read(customerServiceProvider)
                              .refundCashFromWallet(
                                customerId: id,
                                amountKobo: amountKobo,
                                method: method,
                                staffId: staffId,
                                note: note.isEmpty ? null : note,
                              );
                          messenger.showSnackBar(
                            refundedKobo <= 0
                                ? const SnackBar(
                                    content: Text('Nothing to refund'),
                                  )
                                : SnackBar(
                                    content: Text(
                                      '${formatCurrency(refundedKobo / 100)} refunded'
                                      '${inDebt ? ' to wallet' : ''}',
                                    ),
                                    backgroundColor: success,
                                  ),
                          );
                        } catch (_) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('Could not process refund'),
                            ),
                          );
                        }
                      },
                    ),
                    SizedBox(
                      height: ctx.deviceBottomInset + ctx.getRSize(16),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _refundAvailRow(
    BuildContext ctx,
    String label,
    int kobo,
    Color onSurface, {
    bool bold = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ctx.getRSize(2)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: ctx.getRFontSize(13),
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              color: bold ? onSurface : onSurface.withAlpha(178),
            ),
          ),
          Text(
            formatCurrency(kobo / 100),
            style: TextStyle(
              fontSize: ctx.getRFontSize(13),
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
              color: onSurface,
            ),
          ),
        ],
      ),
    );
  }

  void _showSetLimitSheet() {
    final limitCtrl = TextEditingController(
      text: _limitKobo > 0 ? (_limitKobo / 100).toStringAsFixed(0) : '',
    );
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SheetContainer(
        scrollController: ScrollController(),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetHandle(),
              Text(
                'Set Debt Limit',
                style: TextStyle(
                  fontSize: ctx.getRFontSize(20),
                  fontWeight: FontWeight.w800,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
              SizedBox(height: ctx.getRSize(4)),
              Text(
                'Maximum credit allowed for $_name',
                style: TextStyle(
                  fontSize: ctx.getRFontSize(13),
                  color: Theme.of(ctx).colorScheme.onSurface.withAlpha(128),
                ),
              ),
              SizedBox(height: ctx.getRSize(24)),
              _SheetField(
                controller: limitCtrl,
                label: 'Limit Amount (₦)',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [CurrencyInputFormatter()],
                validator: (v) {
                  final n = parseCurrency(v ?? '');
                  if (n < 0) {
                    return 'Enter a valid amount (0 to remove limit)';
                  }
                  return null;
                },
              ),
              SizedBox(height: ctx.getRSize(24)),
              AmberButton(
                label: 'Save Limit',
                icon: Icons.check,
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  final amount = parseCurrency(limitCtrl.text);
                  final id = _customerId;
                  if (id == null) return;
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(ctx);
                  await ref
                      .read(customerServiceProvider)
                      .updateWalletLimit(id, amount);
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Debt limit set to ${formatCurrency(amount)}',
                      ),
                      backgroundColor: success,
                    ),
                  );
                },
              ),
              SizedBox(
                height: ctx.deviceBottomInset + ctx.getRSize(16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// §18.4 / §18.5 — confirm, then soft-delete the customer. History stays
  /// intact (soft-delete only); on success we pop back to the list.
  Future<void> _confirmAndDelete() async {
    final id = _customerId;
    if (id == null) return;
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        title: const Text('Delete customer?'),
        content: Text(
          '$_name will be removed from your customer list. '
          'Their sales and wallet history stay intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name;
    await ref.read(customerServiceProvider).softDeleteCustomer(id);
    if (!mounted) return;
    Navigator.pop(context); // back to the customers list
    messenger.showSnackBar(
      SnackBar(content: Text('$name deleted'), backgroundColor: success),
    );
  }

  /// §18 — open the prefilled Edit Customer Details sheet (CEO/Manager only,
  /// `customers.update`). Prefill comes from the live watched row, falling back
  /// to the row this screen was opened with.
  void _openEditSheet() {
    final id = _customerId;
    if (id == null || id == Customer.walkInId) return;
    // Defense-in-depth: re-check at the open boundary (hard rule #6).
    if (!hasPermission(ref, 'customers.update')) return;

    var tier = PriceTier.retailer;
    try {
      tier = PriceTier.values.firstWhere((e) => e.name == _groupName);
    } catch (_) {}

    EditCustomerSheet.show(
      context,
      customerId: id,
      initialName: _customerData?.name ?? widget.customer?.name ?? '',
      initialPhone: _customerData?.phone ?? widget.customer?.phone ?? '',
      initialAddress: _customerData?.address ?? '',
      initialLocation: _customerData?.googleMapsLocation ?? '',
      initialPriceTier: tier,
      initialStoreId: _customerData?.storeId ?? widget.customer?.storeId,
    );
  }

  void _showReceipt(OrderData order) async {
    final db = ref.read(databaseProvider);
    final itemRows = await (db.select(db.orderItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.orderItems.productId)),
    ])..where(db.orderItems.orderId.equals(order.id))).get();

    final items = itemRows.map((row) {
      final p = row.readTable(db.products);
      final i = row.readTable(db.orderItems);
      return {
        'name': p.name,
        'qty': i.quantity,
        'price': i.unitPriceKobo / 100.0,
      };
    }).toList();

    // Resolve store address (country excluded, §15.1) from the order's store
    String? storeAddress;
    if (order.storeId != null) {
      final stores = await db.storesDao.getActiveStores();
      storeAddress = stores
          .where((w) => w.id == order.storeId)
          .map((w) => receiptStoreAddress(w.location))
          .firstOrNull;
    }

    if (!mounted) return;

    DateTime? reprintDate;
    DateTime? reshareDate;
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final borderCol = Theme.of(context).dividerColor;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: MediaQuery.of(ctx).size.height * 0.85,
              decoration: BoxDecoration(
                color: surfaceCol,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    margin: EdgeInsets.symmetric(vertical: ctx.getRSize(12)),
                    width: ctx.getRSize(40),
                    height: ctx.getRSize(5),
                    decoration: BoxDecoration(
                      color: borderCol,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        ctx.getRSize(20),
                        ctx.getRSize(10),
                        ctx.getRSize(20),
                        ctx.getRSize(30),
                      ),
                      child: Screenshot(
                        controller: _screenshotCtrl,
                        child: ReceiptWidget(
                          orderId: order.orderNumber,
                          cart: items,
                          subtotal:
                              (order.totalAmountKobo -
                                  order.crateDepositPaidKobo) /
                              100.0,
                          crateDeposit: order.crateDepositPaidKobo / 100.0,
                          total: order.totalAmountKobo / 100.0,
                          paymentMethod: order.paymentType,
                          customerName: _name,
                          customerPhone: _phone,
                          customerAddress: _address,
                          cashReceived: order.amountPaidKobo / 100.0,
                          orderStatus:
                              order.status[0].toUpperCase() +
                              order.status.substring(1),
                          riderName: order.riderName,
                          reprintDate: reprintDate,
                          reshareDate: reshareDate,
                          storeAddress: storeAddress,
                          businessName: ref.read(currentBusinessNameProvider),
                        ),
                      ),
                    ),
                  ),
                  // useSafeArea: true wraps the sheet in SafeArea(bottom: false)
                  // (no bottom inset), and MainLayout's Scaffold zeroes
                  // padding.bottom for everything under it — so ctx.bottomInset
                  // reads 0 here. deviceBottomInset reads the real nav inset from
                  // the raw view so the button bar clears the system nav.
                  Padding(
                    padding: EdgeInsets.all(ctx.getRSize(16)).add(
                      EdgeInsets.only(bottom: ctx.deviceBottomInset),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            text: 'Print',
                            icon: FontAwesomeIcons.print,
                            onPressed: () {
                              setModalState(
                                () => reprintDate = DateTime.now(),
                              );
                              _printReceiptFromDetail(
                                ctx,
                                order,
                                items,
                                storeAddress,
                              );
                            },
                          ),
                        ),
                        SizedBox(width: ctx.getRSize(12)),
                        Expanded(
                          child: AppButton(
                            text: 'Share',
                            icon: FontAwesomeIcons.shareNodes,
                            variant: AppButtonVariant.secondary,
                            onPressed: () async {
                              setModalState(
                                () => reshareDate = DateTime.now(),
                              );
                              await Future.delayed(
                                const Duration(milliseconds: 100),
                              );
                              if (ctx.mounted) {
                                _shareReceiptFromDetail(
                                  ctx,
                                  order.orderNumber,
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      reprintDate = null;
      reshareDate = null;
    });
  }

  Future<void> _printReceiptFromDetail(
    BuildContext ctx,
    OrderData order,
    List<Map<String, dynamic>> items,
    String? storeAddress,
  ) async {
    try {
      final granted = await ref
          .read(printerServiceProvider)
          .requestPermissions();
      if (!granted) {
        if (!ctx.mounted) return;
        AppNotification.showError(ctx, 'Bluetooth permissions denied');
        return;
      }

      final bytes = await ThermalReceiptService.buildReceipt(
        orderId: order.orderNumber,
        cart: items,
        subtotal: (order.totalAmountKobo - order.crateDepositPaidKobo) / 100.0,
        crateDeposit: order.crateDepositPaidKobo / 100.0,
        total: order.totalAmountKobo / 100.0,
        paymentMethod: order.paymentType,
        customerName: _name,
        customerAddress: _address,
        cashReceived: order.amountPaidKobo / 100.0,
        reprintDate: DateTime.now(),
        riderName: order.riderName,
        orderStatus: order.status,
        refundAmount: order.amountPaidKobo / 100.0,
        storeAddress: storeAddress,
        businessName: ref.read(currentBusinessNameProvider),
      );

      if (!ctx.mounted) return;

      final success = await ref.read(printerServiceProvider).printBytes(bytes);
      if (success) {
        if (!ctx.mounted) return;
        AppNotification.showSuccess(ctx, 'Print successful');
        return;
      }

      if (ctx.mounted) {
        showModalBottomSheet(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.5,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => PrinterPicker(
            onSelected: (device) async {
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (!ctx.mounted) return;
              AppNotification.showSuccess(
                ctx,
                'Connecting to ${device.name}...',
              );
              final connected = await ref
                  .read(printerServiceProvider)
                  .connect(device.macAdress);
              if (!mounted) return;
              if (connected) {
                await ref
                    .read(printerServiceProvider)
                    .saveLastConnectedMac(device.macAdress);
                await ref.read(printerServiceProvider).printBytes(bytes);
                if (!ctx.mounted) return;
                AppNotification.showSuccess(ctx, 'Print successful');
              } else {
                if (!ctx.mounted) return;
                AppNotification.showError(
                  ctx,
                  'Failed to connect to ${device.name}',
                );
              }
            },
          ),
        );
      }
    } catch (e) {
      if (ctx.mounted) AppNotification.showError(ctx, 'Error printing: $e');
    }
  }

  Future<void> _shareReceiptFromDetail(
    BuildContext ctx,
    String orderNumber,
  ) async {
    try {
      final Uint8List? imageBytes = await _screenshotCtrl.capture(
        delay: const Duration(milliseconds: 50),
        pixelRatio: 3.0,
      );
      if (imageBytes == null) return;

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/receipt_$orderNumber.png');
      await file.writeAsBytes(imageBytes);

      if (!ctx.mounted) return;
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: 'Receipt #$orderNumber');
    } catch (e) {
      if (ctx.mounted) AppNotification.showError(ctx, 'Error sharing: $e');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  /// §18.3 — the Crates tab only shows for Bar / Beer Distributor businesses.
  /// Same business-type gate the Inventory screen uses for its Empty Crates tab.
  bool _showCratesTab() {
    final businessesAsync = ref.watch(localBusinessesProvider);
    if (!businessesAsync.hasValue) return false;
    final businessId = ref.read(authProvider).currentUser?.businessId;
    final type = businessesAsync.value!
        .where((b) => b.id == businessId)
        .map((b) => b.type)
        .firstOrNull;
    return isCrateBusiness(type);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    final showCrates = _showCratesTab();

    return DefaultTabController(
      length: showCrates ? 3 : 2,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: theme.colorScheme.surface,
          elevation: 0,
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new,
              size: context.getRSize(20),
              color: theme.colorScheme.onSurface,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          title: Row(
            children: [
              Container(
                padding: EdgeInsets.all(context.getRSize(8)),
                decoration: AppDecorations.primaryGradient(context, radius: 12),
                child: Icon(
                  FontAwesomeIcons.user,
                  color: Colors.white,
                  size: context.getRSize(16),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Customer Profile',
                        style: TextStyle(
                          fontSize: context.getRFontSize(18),
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.onSurface,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    Text(
                      'Account Details',
                      style: TextStyle(
                        fontSize: context.getRFontSize(11),
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          centerTitle: false,
          actions: [
            // §18.4 — soft-delete, CEO/Manager only (customers.delete). Never
            // for the synthetic walk-in (its id is non-null Customer.walkInId).
            if (_customerId != null &&
                _customerId != Customer.walkInId &&
                hasPermission(ref, 'customers.delete'))
              IconButton(
                icon: Icon(
                  FontAwesomeIcons.trashCan,
                  size: context.getRSize(18),
                  color: danger,
                ),
                tooltip: 'Delete customer',
                onPressed: _confirmAndDelete,
              ),
            const NotificationBell(),
            SizedBox(width: context.getRSize(8)),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async {
            _loadData();
            await Future.delayed(const Duration(milliseconds: 500));
          },
          color: theme.colorScheme.primary,
          child: _contentReady
              ? _buildContent(theme, showCrates)
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, bool showCrates) {
    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) {
        return [
          SliverToBoxAdapter(child: _buildHeader(theme)),
          SliverToBoxAdapter(child: _buildWalletCard(theme)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _SliverTabBarDelegate(
              child: Container(
                color: theme.scaffoldBackgroundColor,
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: _buildTabBar(theme, showCrates),
              ),
            ),
          ),
        ];
      },
      body: TabBarView(
        children: [
          _buildWalletHistoryTab(theme),
          _buildOrdersTab(theme),
          if (showCrates) _buildCratesTab(theme),
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _buildHeader(ThemeData theme) {
    final isWholesaler = _groupName == 'wholesaler';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(4),
        context.getRSize(20),
        context.getRSize(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: context.getRSize(60),
            height: context.getRSize(60),
            decoration: AppDecorations.primaryGradient(context, radius: 30),
            child: Center(
              child: Text(
                _initials(_name),
                style: TextStyle(
                  fontSize: context.getRFontSize(22),
                  fontWeight: FontWeight.w900,
                  color: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Name + edit pen on the left; tier badge pinned right.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              _name,
                              style: TextStyle(
                                fontSize: context.getRFontSize(18),
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          // §18 — edit pen, CEO/Manager only (customers.update).
                          // Never for the synthetic walk-in.
                          if (_customerId != null &&
                              _customerId != Customer.walkInId &&
                              hasPermission(ref, 'customers.update')) ...[
                            SizedBox(width: context.getRSize(6)),
                            InkWell(
                              onTap: _openEditSheet,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: EdgeInsets.all(context.getRSize(4)),
                                child: Icon(
                                  FontAwesomeIcons.penToSquare,
                                  size: context.getRSize(15),
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    StatusBadge(
                      label: isWholesaler ? 'Wholesaler' : 'Retailer',
                      variant: isWholesaler
                          ? BadgeVariant.green
                          : BadgeVariant.amber,
                    ),
                  ],
                ),
                if (_phone.isNotEmpty) ...[
                  SizedBox(height: context.getRSize(6)),
                  _InfoRow(
                    icon: FontAwesomeIcons.phone,
                    text: _phone,
                    theme: theme,
                  ),
                ],
                if (_address.isNotEmpty && _address != 'N/A') ...[
                  SizedBox(height: context.getRSize(4)),
                  _InfoRow(
                    icon: FontAwesomeIcons.locationDot,
                    text: _address,
                    theme: theme,
                  ),
                ],
                SizedBox(height: context.getRSize(4)),
                _InfoRow(
                  icon: FontAwesomeIcons.calendarCheck,
                  text: 'Since ${DateFormat('MMM yyyy').format(_joinedAt)}',
                  theme: theme,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Wallet Card ─────────────────────────────────────────────────────────────

  Widget _buildWalletCard(ThemeData theme) {
    final balance = _walletBalance / 100.0;
    final limit = _limitKobo / 100.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(18)),
        decoration: AppDecorations.surfaceCard(context, radius: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.wallet,
                  size: context.getRSize(14),
                  color: theme.colorScheme.primary,
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  'Wallet Balance',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withAlpha(128),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              formatCurrency(balance),
              style: TextStyle(
                fontSize: context.getRFontSize(28),
                fontWeight: FontWeight.w900,
                color: balance >= 0 ? theme.colorScheme.onSurface : danger,
                letterSpacing: -1,
              ),
            ),
            SizedBox(height: context.getRSize(4)),
            Row(
              children: [
                Icon(
                  FontAwesomeIcons.creditCard,
                  size: context.getRSize(12),
                  color: theme.colorScheme.onSurface.withAlpha(102),
                ),
                SizedBox(width: context.getRSize(6)),
                Text(
                  limit > 0
                      ? 'Debt limit: ${formatCurrency(limit)}'
                      : 'No debt limit set',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: theme.colorScheme.onSurface.withAlpha(128),
                  ),
                ),
              ],
            ),
            // §13.4 decision 14 — the refundable crate deposit, shown as its own
            // line so it's never mistaken for spendable balance. The figure
            // above (Wallet Balance) already excludes it.
            if (_depositsHeld != 0) ...[
              SizedBox(height: context.getRSize(4)),
              Row(
                children: [
                  Icon(
                    FontAwesomeIcons.boxOpen,
                    size: context.getRSize(12),
                    color: theme.colorScheme.primary.withAlpha(178),
                  ),
                  SizedBox(width: context.getRSize(6)),
                  Text(
                    'Crate deposit held: ${formatCurrency(_depositsHeld / 100.0)}',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
            SizedBox(height: context.getRSize(14)),
            Row(
              children: [
                Text(
                  'Period:',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withAlpha(128),
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: DropdownButton<String>(
                    value: _effectivePeriod,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    dropdownColor: theme.colorScheme.surface,
                    icon: Icon(
                      FontAwesomeIcons.chevronDown,
                      size: context.getRSize(11),
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                    items: _periodOptions
                        .map(
                          (p) => DropdownMenuItem(value: p, child: Text(p)),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _selectedPeriod = v ?? 'To Date'),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(14)),
            Builder(
              builder: (context) {
                // §18.4 — Add Funds: CEO/Manager/Cashier (customers.wallet.update).
                // Set debt limit: CEO/Manager only (customers.set_debt_limit).
                // Refund Cash: CEO/Manager only (customers.wallet.withdraw).
                final canAddFunds =
                    hasPermission(ref, 'customers.wallet.update');
                final canSetLimit =
                    hasPermission(ref, 'customers.set_debt_limit');
                final canRefund =
                    hasPermission(ref, 'customers.wallet.withdraw');
                return Column(
                  children: [
                    Row(
                      children: [
                        if (canAddFunds)
                          Expanded(
                            child: AmberButton(
                              label: 'Add Funds',
                              icon: FontAwesomeIcons.plus,
                              height: 42,
                              onPressed: _showAddFundsSheet,
                            ),
                          ),
                        if (canAddFunds && canSetLimit)
                          SizedBox(width: context.getRSize(10)),
                        if (canSetLimit)
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _showSetLimitSheet,
                              icon: Icon(
                                FontAwesomeIcons.penToSquare,
                                size: 14,
                                color: theme.colorScheme.onSurface,
                              ),
                              label: Text(
                                'Set Limit',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(14),
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: Size(0, context.getRSize(42)),
                                side: BorderSide(color: theme.dividerColor),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (canRefund) ...[
                      SizedBox(height: context.getRSize(10)),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _showRefundCashSheet,
                          icon: Icon(
                            FontAwesomeIcons.moneyBillTransfer,
                            size: 14,
                            color: theme.colorScheme.onSurface,
                          ),
                          label: Text(
                            'Refund Cash',
                            style: TextStyle(
                              fontSize: context.getRFontSize(14),
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            minimumSize: Size(0, context.getRSize(42)),
                            side: BorderSide(color: theme.dividerColor),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab Bar ─────────────────────────────────────────────────────────────────

  Widget _buildTabBar(ThemeData theme, bool showCrates) {
    return TabBar(
      labelColor: theme.colorScheme.primary,
      unselectedLabelColor: theme.colorScheme.onSurface.withAlpha(115),
      indicatorColor: theme.colorScheme.primary,
      indicatorSize: TabBarIndicatorSize.tab,
      labelStyle: TextStyle(
        fontSize: context.getRFontSize(13),
        fontWeight: FontWeight.w700,
      ),
      tabs: [
        const Tab(
          icon: Icon(FontAwesomeIcons.clockRotateLeft, size: 16),
          text: 'Wallet',
        ),
        const Tab(
          icon: Icon(FontAwesomeIcons.fileLines, size: 16),
          text: 'Orders',
        ),
        if (showCrates)
          const Tab(
            icon: Icon(FontAwesomeIcons.boxOpen, size: 16),
            text: 'Crates',
          ),
      ],
    );
  }

  // ── Wallet Summary ──────────────────────────────────────────────────────────

  Widget _buildSummaryTile(
    ThemeData theme,
    String label,
    double amount,
    Color color,
  ) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(10),
      ),
      decoration: AppDecorations.surfaceCard(context, radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withAlpha(128),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency(amount),
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWalletSummaryRow(ThemeData theme) {
    int totalInKobo = 0, totalOutKobo = 0;
    for (final txn in _filteredHistory) {
      // §13.4 decision 13 — Total In/Out is spendable money; the refundable
      // crate-deposit slice is shown separately, never folded in here.
      if (kCrateDepositReferenceTypes.contains(txn.referenceType)) continue;
      if (txn.type == 'credit') {
        totalInKobo += txn.amountKobo;
      } else {
        totalOutKobo += txn.amountKobo;
      }
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSummaryTile(
              theme,
              'Total In',
              totalInKobo / 100.0,
              success,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: _buildSummaryTile(
              theme,
              'Total Out',
              totalOutKobo / 100.0,
              danger,
            ),
          ),
        ],
      ),
    );
  }

  // ── Tab: Wallet History ─────────────────────────────────────────────────────

  Widget _buildWalletHistoryTab(ThemeData theme) {
    if (_walletHistory.isEmpty) {
      return _EmptyState(
        icon: FontAwesomeIcons.hourglass,
        message: 'No wallet transactions yet',
        theme: theme,
      );
    }

    final filtered = _filteredHistory;

    return Column(
      children: [
        // §18.4: Total In / Total Out are gated by `customers.wallet.totals.view`
        // (granted to Manager + CEO by default; the CEO can revoke it per staff
        // member). Read the effective permission — no role-tier bypass — so a
        // per-user override actually takes effect.
        if (hasPermission(ref, 'customers.wallet.totals.view')) ...[
          _buildWalletSummaryRow(theme),
          SizedBox(height: context.getRSize(4)),
        ],
        Expanded(
          child: filtered.isEmpty
              ? _EmptyState(
                  icon: FontAwesomeIcons.filterCircleXmark,
                  message: 'No transactions in this period',
                  theme: theme,
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(20),
                    context.getRSize(12),
                    context.getRSize(20),
                    context.getRSize(20) + context.deviceBottomInset,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final txn = filtered[i];
                    final isCredit = txn.type == 'credit';
                    final amount = txn.amountKobo / 100.0;
                    final color = isCredit ? success : danger;
                    return Padding(
                      padding: EdgeInsets.only(bottom: ctx.getRSize(10)),
                      child: Container(
                        padding: EdgeInsets.all(ctx.getRSize(14)),
                        decoration: AppDecorations.surfaceCard(ctx, radius: 12),
                        child: Row(
                          children: [
                            Container(
                              width: ctx.getRSize(38),
                              height: ctx.getRSize(38),
                              decoration: BoxDecoration(
                                color: color.withAlpha(30),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isCredit
                                    ? FontAwesomeIcons.arrowDown
                                    : FontAwesomeIcons.arrowUp,
                                color: color,
                                size: ctx.getRSize(16),
                              ),
                            ),
                            SizedBox(width: ctx.getRSize(12)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _friendlyRefType(txn.referenceType),
                                    style: TextStyle(
                                      fontSize: ctx.getRFontSize(14),
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  Text(
                                    DateFormat(
                                      'd MMM yyyy, h:mm a',
                                    ).format(txn.createdAt),
                                    style: TextStyle(
                                      fontSize: ctx.getRFontSize(11),
                                      color: theme.colorScheme.onSurface
                                          .withAlpha(115),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${isCredit ? '+' : '-'}${formatCurrency(amount)}',
                              style: TextStyle(
                                fontSize: ctx.getRFontSize(15),
                                fontWeight: FontWeight.w800,
                                color: color,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Tab: Orders ─────────────────────────────────────────────────────────────

  Widget _buildOrdersTab(ThemeData theme) {
    if (_orders.isEmpty) {
      return _EmptyState(
        icon: FontAwesomeIcons.receipt,
        message: 'No orders placed yet',
        theme: theme,
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(20) + context.deviceBottomInset,
      ),
      itemCount: _orders.length,
      itemBuilder: (ctx, i) {
        final order = _orders[i];
        final total = order.totalAmountKobo / 100.0;
        return Padding(
          padding: EdgeInsets.only(bottom: ctx.getRSize(10)),
          child: InkWell(
            onTap: () => _showReceipt(order),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: EdgeInsets.all(ctx.getRSize(14)),
              decoration: AppDecorations.surfaceCard(ctx, radius: 12),
              child: Row(
                children: [
                  Container(
                    width: ctx.getRSize(38),
                    height: ctx.getRSize(38),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withAlpha(25),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      FontAwesomeIcons.receipt,
                      color: theme.colorScheme.primary,
                      size: ctx.getRSize(16),
                    ),
                  ),
                  SizedBox(width: ctx.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${order.orderNumber}',
                          style: TextStyle(
                            fontSize: ctx.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          DateFormat('d MMM yyyy').format(order.createdAt),
                          style: TextStyle(
                            fontSize: ctx.getRFontSize(11),
                            color: theme.colorScheme.onSurface.withAlpha(115),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatCurrency(total),
                        style: TextStyle(
                          fontSize: ctx.getRFontSize(14),
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: ctx.getRSize(4)),
                      StatusBadge(
                        label:
                            order.status[0].toUpperCase() +
                            order.status.substring(1),
                        variant: _orderStatusVariant(order.status),
                        fontSize: 10,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Tab: Crates ─────────────────────────────────────────────────────────────

  Widget _buildCratesTab(ThemeData theme) {
    // §13.4 — the top "+" card is the single entry point for recording crates a
    // customer has brought back (replaces the old per-row "+"). Gated on
    // sales.make (the till-side transaction permission); hidden otherwise
    // (rule #7). It shows even when there is no crate activity yet, so a return
    // can be recorded as a credit for a brand the customer doesn't owe.
    final canRecord = hasPermission(ref, 'sales.make');
    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(20) + context.deviceBottomInset,
      ),
      children: [
        if (canRecord) ...[
          _buildCrateReturnCard(theme),
          SizedBox(height: context.getRSize(16)),
        ],
        if (_crateBalances.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(28)),
            child: Text(
              'No crate activity recorded',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: theme.colorScheme.onSurface.withAlpha(128),
              ),
            ),
          )
        else
          ..._crateBalances.map((entry) => _buildCrateBalanceRow(theme, entry)),
      ],
    );
  }

  // The "+" action card pinned at the top of the Crates tab.
  Widget _buildCrateReturnCard(ThemeData theme) {
    return InkWell(
      onTap: _showRecordCrateReturnSheet,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.primary.withAlpha(60)),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(38),
              height: context.getRSize(38),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                FontAwesomeIcons.plus,
                color: theme.colorScheme.primary,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Record crate return',
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    'Enter crates brought back, by manufacturer',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: theme.colorScheme.onSurface.withAlpha(140),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              FontAwesomeIcons.chevronRight,
              size: context.getRSize(13),
              color: theme.colorScheme.onSurface.withAlpha(100),
            ),
          ],
        ),
      ),
    );
  }

  // One per-manufacturer balance row (owed / clear / credit).
  Widget _buildCrateBalanceRow(ThemeData theme, CrateBalanceEntry entry) {
    final bal = entry.balance;
    final isOwe = bal > 0;
    final isClear = bal == 0;
    final color = isClear
        ? theme.colorScheme.onSurface.withAlpha(102)
        : isOwe
        ? theme.colorScheme.primary
        : success;
    final label = isClear
        ? 'Clear'
        : isOwe
        ? '${bal.abs()} crates owed'
        : '${bal.abs()} crates credit';
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: Container(
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: AppDecorations.surfaceCard(context, radius: 12),
        child: Row(
          children: [
            Container(
              width: context.getRSize(38),
              height: context.getRSize(38),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                FontAwesomeIcons.boxOpen,
                color: color,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                entry.manufacturerName,
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(10),
                vertical: context.getRSize(4),
              ),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// §13.4 — record crates a customer has brought back (outside an order), from
  /// the Crates tab's top "+" card. Pick a manufacturer + enter the count.
  /// Adds the empties to physical stock and nets the customer's balance via the
  /// same ledger the order-return flow uses (recordCrateReturnByCustomer): it
  /// reduces an owed balance, or — when the customer owes nothing for that brand
  /// — records a crate credit (we now hold their crates). Live via the stream.
  Future<void> _showRecordCrateReturnSheet() async {
    final id = _customerId;
    if (id == null) return;
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null || staffId.isEmpty) {
      AppNotification.showError(context, 'No active session.');
      return;
    }
    final db = ref.read(databaseProvider);
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    if (!mounted) return;
    if (manufacturers.isEmpty) {
      AppNotification.showError(context, 'Add a manufacturer first.');
      return;
    }

    String? selectedId;
    final qtyCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => _SheetContainer(
          scrollController: ScrollController(),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetHandle(),
                Text(
                  'Record Crate Return',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: ctx.getRFontSize(18),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: ctx.getRSize(4)),
                Text(
                  'Crates brought back by the customer',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: ctx.getRFontSize(13),
                    color: Theme.of(ctx).colorScheme.onSurface.withAlpha(128),
                  ),
                ),
                SizedBox(height: ctx.getRSize(24)),
                AppDropdown<String>(
                  value: selectedId,
                  labelText: 'Manufacturer',
                  hintText: 'Select a manufacturer',
                  items: manufacturers
                      .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.name),
                          ))
                      .toList(),
                  onChanged: (v) => setSheetState(() => selectedId = v),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Select a manufacturer' : null,
                ),
                SizedBox(height: ctx.getRSize(16)),
                _SheetField(
                  controller: qtyCtrl,
                  label: 'Crates returned',
                  keyboard: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    final n = int.tryParse((v ?? '').trim()) ?? 0;
                    if (n <= 0) return 'Enter how many crates came back';
                    return null;
                  },
                ),
                SizedBox(height: ctx.getRSize(24)),
                AmberButton(
                  label: 'Record Return',
                  icon: Icons.check,
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    final mfrId = selectedId!;
                    final qty = int.parse(qtyCtrl.text.trim());
                    final mfrName =
                        manufacturers.firstWhere((m) => m.id == mfrId).name;
                    final messenger = ScaffoldMessenger.of(context);
                    // Write-boundary re-check (§10.2.1): honor a revoked override.
                    if (!ref
                        .read(currentUserPermissionsProvider)
                        .contains('sales.make')) {
                      Navigator.pop(ctx);
                      messenger.showSnackBar(
                        const SnackBar(
                          content:
                              Text('You don\'t have permission to do that.'),
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    try {
                      await db.inventoryDao.addEmptyCrates(mfrId, qty);
                      await db.crateLedgerDao.recordCrateReturnByCustomer(
                        customerId: id,
                        manufacturerId: mfrId,
                        quantity: qty,
                        performedBy: staffId,
                      );
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            '$qty crate${qty == 1 ? '' : 's'} returned for '
                            '$mfrName',
                          ),
                          backgroundColor: success,
                        ),
                      );
                    } catch (_) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Could not record the return'),
                        ),
                      );
                    }
                  },
                ),
                SizedBox(height: ctx.deviceBottomInset + ctx.getRSize(16)),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final ThemeData theme;
  const _InfoRow({required this.icon, required this.text, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: context.getRSize(12),
          color: theme.colorScheme.primary.withValues(alpha: 0.7),
        ),
        SizedBox(width: context.getRSize(6)),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final ThemeData theme;
  const _EmptyState({
    required this.icon,
    required this.message,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: context.getRSize(40),
            color: theme.colorScheme.onSurface.withAlpha(51),
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            message,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              color: theme.colorScheme.onSurface.withAlpha(102),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetContainer extends StatelessWidget {
  final ScrollController scrollController;
  final Widget child;
  const _SheetContainer({required this.scrollController, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        context.getRSize(8),
      ),
      child: child,
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface.withAlpha(51),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType keyboard;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  const _SheetField({
    required this.controller,
    required this.label,
    required this.keyboard,
    this.inputFormatters,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboard,
      inputFormatters: inputFormatters,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  _SliverTabBarDelegate({required this.child});

  @override
  double get minExtent => 60;
  @override
  double get maxExtent => 60;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}
