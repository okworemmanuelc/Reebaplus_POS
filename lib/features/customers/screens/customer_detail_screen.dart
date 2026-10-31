import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:drift/drift.dart' show innerJoin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_extras.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:flutter/services.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_payment_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/edit_customer_sheet.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/core/providers/online_order_providers.dart';
import 'package:reebaplus_pos/shared/models/receipt_totals.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_paper_size_prompt.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

const String kCustomerCreditRowKeyPrefix = 'customer-credit-row-';

class CustomerDetailScreen extends ConsumerStatefulWidget {
  final Customer? customer;

  const CustomerDetailScreen({super.key, this.customer});

  @override
  ConsumerState<CustomerDetailScreen> createState() =>
      _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen>
    with TickerProviderStateMixin {
  bool _contentReady = false;
  final ScreenshotController _screenshotCtrl = ScreenshotController();

  late TabController _tabController;
  List<String> _tabKeys = const ['credits', 'orders'];

  CustomerData? _customerData;
  int _creditBalance = 0;
  int _depositsHeld = 0; // §13.4 — refundable crate deposit held (kobo)
  List<WalletTransactionData> _creditHistory = [];
  String _selectedPeriod = 'To Date'; // §30.11 canonical chip set
  DateTimeRange? _customRange;
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
    _tabKeys = _resolveTabKeys(
      businessTracksCrates(ref.read(currentBusinessProvider)),
    );
    _tabController = TabController(length: _tabKeys.length, vsync: this);
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
      if (mounted) setState(() => _creditBalance = bal);
    });

    _depositsHeldSub = db.customersDao.watchWalletDepositsHeldKobo(id).listen((
      held,
    ) {
      if (mounted) setState(() => _depositsHeld = held);
    });

    _historySub = db.customersDao.watchWalletHistory(id).listen((hist) {
      if (mounted) setState(() => _creditHistory = hist);
    });

    _ordersSub = ref
        .read(orderServiceProvider)
        .watchOrdersByCustomer(id)
        .listen((orders) {
          if (mounted) setState(() => _orders = orders);
        });

    _cratesSub = db.customersDao.watchCrateBalancesWithGroups(id).listen((
      crates,
    ) {
      if (mounted) setState(() => _crateBalances = crates);
    });

    if (mounted) setState(() => _contentReady = true);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _customerSub?.cancel();
    _balanceSub?.cancel();
    _depositsHeldSub?.cancel();
    _historySub?.cancel();
    _ordersSub?.cancel();
    _cratesSub?.cancel();
    super.dispose();
  }

  List<String> _resolveTabKeys(bool showCrates) => [
    'credits',
    'orders',
    if (showCrates) 'crates',
  ];

  void _syncTabController(List<String> keys) {
    if (_listEquals(keys, _tabKeys)) return;
    final priorIndex = _tabController.index;
    final newIndex = priorIndex.clamp(0, keys.length - 1);
    _tabKeys = keys;
    if (_tabController.length != keys.length) {
      _tabController.dispose();
      _tabController = TabController(
        length: keys.length,
        vsync: this,
        initialIndex: newIndex,
      );
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _name => _customerData?.name ?? widget.customer?.name ?? '?';
  String get _phone => _customerData?.phone ?? widget.customer?.phone ?? '';
  String get _address =>
      _customerData?.address ?? widget.customer?.addressText ?? '';
  String get _groupName =>
      _customerData?.priceTier ?? widget.customer?.priceTier.name ?? 'retailer';
  DateTime get _joinedAt =>
      _customerData?.createdAt ?? widget.customer?.createdAt ?? DateTime.now();
  int get _limitKobo =>
      _customerData?.walletLimitKobo ?? widget.customer?.walletLimitKobo ?? 0;
  String? get _customerId => widget.customer?.id;

  /// Period labels this viewer may choose (§19.2/§30.11 — roles below Manager
  /// are capped to Today/This Week/This Month).
  List<String> get _periodOptions => datePeriodLabelsForRole(
    managerUp: Gates.seeExtendedDateRanges.allows(ref),
  );

  /// [_selectedPeriod] clamped into [_periodOptions], so the dropdown value and
  /// the filter agree for capped viewers (default is "To Date", out of their set).
  String get _effectivePeriod {
    final isCustom = _selectedPeriod.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _selectedPeriod;
    if (_periodOptions.contains(dropdownValue)) {
      return _selectedPeriod;
    }
    return _periodOptions.first;
  }

  List<WalletTransactionData> get _filteredHistory {
    return _creditHistory
        .where((txn) => isDateInPeriod(txn.createdAt, _effectivePeriod))
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
        return 'Cash credit added';
      case 'topup_transfer':
        return 'Transfer credit added';
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

  TagPillTone _orderStatusTone(String status) {
    switch (status) {
      case 'completed':
        return TagPillTone.green;
      case 'cancelled':
      // LEGACY ROWS ONLY (#196): `refunded` is a retired status (PRD #155 moved
      // refunds to `payment_transactions`); nothing writes it, but a historic
      // order that carries it still renders in this customer's history and reads
      // as a reversed sale, so it keeps the reversed-sale badge.
      case 'refunded':
        return TagPillTone.danger;
      default:
        return TagPillTone.warning;
    }
  }

  /// The fixed status colours (green / danger), for snackbars and figures.
  AppFixedColors get _fixed =>
      Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

  // ── Sheets ─────────────────────────────────────────────────────────────────

  void _showAddFundsSheet() {
    // The live row when it has loaded, so an edit made on this page shows.
    final data = _customerData;
    final customer = data != null ? Customer.fromDb(data) : widget.customer;
    if (customer == null || _customerId == null) return;
    // §18 Add Credit — the shared customer payment sheet (#362 PR 3),
    // pre-picked, with its balance line and "Pay full" shortcut.
    CustomerPaymentSheet.show(context, customer: customer);
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
        'Nothing to refund — this customer has no credit balance or held '
        'deposit. (Refunds can\'t be drawn from a debt.)',
      );
      return;
    }

    final amountCtrl = TextEditingController(
      text: (availableKobo / 100).toStringAsFixed(
        availableKobo % 100 == 0 ? 0 : 2,
      ),
    );
    final noteCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String selectedMethod = 'cash'; // 'cash' | 'transfer' | 'pos' | 'other'

    showCustomerSheet<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Consumer(
          builder: (ctx, sheetRef, _) {
            final onSurface = Theme.of(ctx).colorScheme.onSurface;
            return CustomerSheetFrame(
              title: inDebt ? 'Refund Deposit' : 'Refund Cash',
              subtitle: inDebt
                  ? 'Refund to $_name\'s credit balance — reduces what they owe'
                  : 'Pay $_name back in cash',
              children: [
                Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // What's available, broken down.
                      DecoratedBox(
                        decoration: AppDecorations.card(ctx),
                        child: Padding(
                          padding: EdgeInsets.all(ctx.getRSize(14)),
                          child: Column(
                            children: [
                              if (creditAvail > 0)
                                _refundAvailRow(
                                  ctx,
                                  'Credit balance',
                                  creditAvail,
                                  onSurface,
                                ),
                              if (depositAvail > 0)
                                _refundAvailRow(
                                  ctx,
                                  'Crate deposit held',
                                  depositAvail,
                                  onSurface,
                                ),
                              if (creditAvail > 0 && depositAvail > 0) ...[
                                Divider(height: ctx.getRSize(16)),
                                _refundAvailRow(
                                  ctx,
                                  'Available',
                                  availableKobo,
                                  onSurface,
                                  bold: true,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SizedBox(height: ctx.getRSize(16)),
                      AppInput(
                        key: CustomersKeys.refundAmount,
                        controller: amountCtrl,
                        labelText: customerAmountLabel('Amount to refund'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
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
                          style: ctx
                              .semiBoldStyle(13)
                              .copyWith(
                                color:
                                    Theme.of(ctx).textTheme.bodySmall?.color ??
                                    onSurface,
                              ),
                        ),
                        SizedBox(height: ctx.getRSize(8)),
                        for (final pair in const [
                          [
                            ('cash', 'Cash', AppIcons.cash),
                            ('transfer', 'Bank Transfer', AppIcons.bank),
                          ],
                          [
                            ('pos', 'POS card', AppIcons.creditCard),
                            ('other', 'Other', AppIcons.moreVertical),
                          ],
                        ]) ...[
                          Row(
                            children: [
                              for (final (i, opt) in pair.indexed) ...[
                                if (i > 0) SizedBox(width: ctx.getRSize(10)),
                                Expanded(
                                  child: CustomerOptionCard(
                                    key: CustomersKeys.refundMethod(opt.$1),
                                    label: opt.$2,
                                    icon: opt.$3,
                                    isSelected: selectedMethod == opt.$1,
                                    onTap: () => setSheetState(
                                      () => selectedMethod = opt.$1,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          SizedBox(height: ctx.getRSize(10)),
                        ],
                      ] else ...[
                        SizedBox(height: ctx.getRSize(12)),
                        Container(
                          padding: EdgeInsets.all(ctx.getRSize(12)),
                          decoration: BoxDecoration(
                            color: _fixed.infoTint,
                            borderRadius: BorderRadius.circular(
                              AppSpacing.borderRadiusL,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppIcon(
                                AppIcons.infoCircle,
                                size: ctx.getRSize(16),
                                color: _fixed.info,
                              ),
                              SizedBox(width: ctx.getRSize(10)),
                              Expanded(
                                child: Text(
                                  'This customer is in debt, so the deposit is '
                                  'added to their credit balance to reduce what they owe — '
                                  'no cash is paid out.',
                                  style: ctx
                                      .regularStyle(12)
                                      .copyWith(color: onSurface),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      SizedBox(height: ctx.getRSize(16)),
                      AppInput(
                        key: CustomersKeys.refundNote,
                        controller: noteCtrl,
                        labelText: 'Note (optional)',
                        keyboardType: TextInputType.text,
                      ),
                      SizedBox(height: ctx.getRSize(24)),
                      AppButton(
                        key: CustomersKeys.refundSubmit,
                        text: inDebt
                            ? 'Refund to Credit Balance'
                            : 'Refund Cash',
                        icon: AppIcons.transfer,
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
                          if (!Gates.refundCustomerWallet.allowsNow(ref)) {
                            Navigator.pop(ctx);
                            showGateDenied(context, Gates.refundCustomerWallet);
                            return;
                          }
                          // The Sales card's Refunds figure is store-filtered, so
                          // an unstamped cash-out vanishes under a locked store
                          // (#194). Same store resolution as Add Credit above.
                          final storeId = ref.read(activeWriteStoreProvider).id;
                          Navigator.pop(ctx);
                          try {
                            final refundedKobo = await ref
                                .read(customerServiceProvider)
                                .refundCashFromWallet(
                                  customerId: id,
                                  amountKobo: amountKobo,
                                  method: method,
                                  staffId: staffId,
                                  storeId: storeId,
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
                                        '${inDebt ? ' to credit balance' : ''}',
                                      ),
                                      backgroundColor: _fixed.green,
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
                    ],
                  ),
                ),
              ],
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
    final muted = Theme.of(ctx).textTheme.bodySmall?.color ?? onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ctx.getRSize(2)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: (bold ? ctx.boldStyle(13) : ctx.mediumStyle(13)).copyWith(
              color: bold ? onSurface : muted,
            ),
          ),
          Text(
            formatCurrency(kobo / 100),
            style: (bold ? ctx.boldStyle(13) : ctx.semiBoldStyle(13)).copyWith(
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

    showCustomerSheet<void>(
      context,
      (ctx) => CustomerSheetFrame(
        title: 'Set Debt Limit',
        subtitle: 'Maximum credit allowed for $_name',
        children: [
          Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppInput(
                  key: CustomersKeys.limitField,
                  controller: limitCtrl,
                  labelText: customerAmountLabel('Limit Amount'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
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
                AppButton(
                  key: CustomersKeys.limitSubmit,
                  text: 'Save Limit',
                  icon: AppIcons.check,
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    final amount = parseCurrency(limitCtrl.text);
                    final id = _customerId;
                    if (id == null) return;
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(ctx);
                    try {
                      await ref
                          .read(customerServiceProvider)
                          .updateWalletLimit(id, amount);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            'Debt limit set to ${formatCurrency(amount)}',
                          ),
                          backgroundColor: _fixed.green,
                        ),
                      );
                    } catch (_) {
                      if (!mounted) return;
                      AppNotification.showError(
                        context,
                        'Could not update the debt limit. Please try again.',
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// §18.4 / §18.5 — confirm, then soft-delete the customer. History stays
  /// intact (soft-delete only); on success we pop back to the list.
  Future<void> _confirmAndDelete() async {
    final id = _customerId;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete customer?'),
        content: Text(
          '$_name will be removed from your customer list. '
          'Their sales and credit history stay intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: customerDangerActionStyle(ctx)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name;
    try {
      await ref.read(customerServiceProvider).softDeleteCustomer(id);
      if (!mounted) return;
      Navigator.pop(context); // back to the customers list
      messenger.showSnackBar(
        SnackBar(content: Text('$name deleted'), backgroundColor: _fixed.green),
      );
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not delete customer. Please try again.',
      );
    }
  }

  /// §18 / PRD #155 (#173) — confirm, then void a mistyped customer credit
  /// top-up (CEO/Manager only, gated on `customers.wallet.withdraw`). Appends
  /// the compensating wallet debit AND the reversal payment row so the amount
  /// drops out of the reconciliation's "Debts collected". Only offered on a
  /// live cash/transfer top-up row.
  Future<void> _confirmVoidTopup(WalletTransactionData txn) async {
    // Defense-in-depth: re-check the gate at the action boundary (hard rule #6).
    if (!Gates.refundCustomerWallet.allowsNow(ref)) return;
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Could not void this top-up yet — no active session.',
      );
      return;
    }
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Void this credit top-up?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatCurrency(txn.amountKobo / 100)} will be reversed from '
              '$_name\'s credit balance and dropped from Debts collected. '
              'This cannot be undone.',
            ),
            SizedBox(height: ctx.getRSize(12)),
            AppInput(controller: reasonCtrl, labelText: 'Reason (optional)'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Void', style: customerDangerActionStyle(ctx)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final reason = reasonCtrl.text.trim();
    try {
      final voided = await ref
          .read(customerServiceProvider)
          .voidTopup(
            walletTxnId: txn.id,
            staffId: staffId,
            reason: reason.isEmpty ? null : reason,
          );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            voided ? 'Top-up voided' : 'This top-up can no longer be voided',
          ),
          backgroundColor: voided ? _fixed.green : _fixed.danger,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not void this top-up. Please try again.',
      );
    }
  }

  /// §18 — open the prefilled Edit Customer Details sheet (CEO/Manager only,
  /// `customers.update`). Prefill comes from the live watched row, falling back
  /// to the row this screen was opened with.
  void _openEditSheet() {
    final id = _customerId;
    if (id == null || id == Customer.walkInId) return;
    // Defense-in-depth: re-check at the open boundary (hard rule #6).
    if (!Gates.editCustomer.allowsNow(ref)) return;

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

  Future<ReceiptExtras> _receiptExtrasFor(OrderData order) async {
    try {
      return await loadReceiptExtrasForOrder(
        ref.read(databaseProvider),
        order,
        business: ref.read(currentBusinessProvider),
        vat: await ref.read(vatConfigProvider.future),
      );
    } catch (_) {
      return ReceiptExtras.none; // optional lines are simply omitted
    }
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
        'unit': p.unit,
        'trackEmpties': p.trackEmpties,
        'manufacturerId': p.manufacturerId,
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

    final mfrList = await db.inventoryDao.watchAllManufacturers().first;
    final manufacturerNames = {for (final m in mfrList) m.id: m.name};
    final extras = await _receiptExtrasFor(order);

    if (!mounted) return;

    DateTime? reprintDate;
    DateTime? reshareDate;
    // #200 / US 33 — rebuild the ORIGINAL receipt's money block from the
    // recorded order so this reprint prints the same Subtotal / Discount /
    // Total. `totalKobo` returns `order.totalAmountKobo` by construction.
    final totals = receiptTotalsFromOrder(
      totalAmountKobo: order.totalAmountKobo,
      crateDepositPaidKobo: order.crateDepositPaidKobo,
      discountKobo: order.discountKobo,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: kCustomerSheetMaxWidth),
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SizedBox(
              height: ctx.sheetMaxHeight(0.85),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: ctx.getRSize(12)),
                    child: const CustomerSheetHandle(),
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
                        child: Consumer(
                          builder: (_, receiptRef, _) => ReceiptWidget(
                            orderId: order.orderNumber,
                            cart: items,
                            subtotal: totals.subtotalKobo / 100.0,
                            discount: totals.discountKobo / 100.0,
                            crateDeposit: totals.depositKobo / 100.0,
                            total: totals.totalKobo / 100.0,
                            // #432 — a Pay on delivery order says so.
                            paymentMethod:
                                receiptRef
                                    .watch(payOnDeliveryByOrderProvider)[
                                        order.id]
                                    ?.label ??
                                paymentMethodLabel(order.paymentType),
                            customerName: _name,
                            cashReceived: order.amountPaidKobo / 100.0,
                            orderStatus:
                                order.status[0].toUpperCase() +
                                order.status.substring(1),
                            reprintDate: reprintDate,
                            reshareDate: reshareDate,
                            storeAddress: storeAddress,
                            businessName: ref.read(currentBusinessNameProvider),
                            businessPhone: extras.businessPhone,
                            businessEmail: extras.businessEmail,
                            cashierName: extras.cashierName,
                            saleDate: extras.saleDate,
                            vatRateBps: extras.vatRateBps,
                            vatIncluded: extras.vatIncluded,
                            cratesOwedByManufacturer: extras.cratesOwedByManufacturer,
                            crateDepositFull: extras.crateDepositFull,
                            // Watched, so the label follows the business row
                            // even when nothing else keeps it loaded (#487).
                            tracksCrates: businessTracksCrates(
                              receiptRef.watch(currentBusinessProvider),
                            ),
                            manufacturerNames: manufacturerNames,
                            logoPath: ref
                                .read(currentBusinessLogoPathProvider)
                                .valueOrNull,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // useSafeArea: true wraps the sheet in SafeArea(bottom: false)
                  // (no bottom inset), and MainLayout's Scaffold zeroes
                  // padding.bottom for everything under it — so ctx.bottomInset
                  // reads 0 here. deviceBottomPadding reads the real nav inset
                  // from the raw view so the bar clears the system nav (MainLayout's
                  // resize handles the keyboard).
                  Padding(
                    padding: EdgeInsets.all(
                      ctx.getRSize(16),
                    ).add(EdgeInsets.only(bottom: ctx.deviceBottomPadding)),
                    child: Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            text: 'Print',
                            icon: AppIcons.print,
                            onPressed: () {
                              setModalState(() => reprintDate = DateTime.now());
                              _printReceiptFromDetail(
                                ctx,
                                order,
                                items,
                                storeAddress,
                                manufacturerNames,
                              );
                            },
                          ),
                        ),
                        SizedBox(width: ctx.getRSize(12)),
                        Expanded(
                          child: AppButton(
                            text: 'Share',
                            icon: AppIcons.share,
                            variant: AppButtonVariant.secondary,
                            onPressed: () async {
                              setModalState(() => reshareDate = DateTime.now());
                              await Future.delayed(
                                const Duration(milliseconds: 100),
                              );
                              if (ctx.mounted) {
                                _shareReceiptFromDetail(ctx, order.orderNumber);
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
    Map<String, String>? manufacturerNames,
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

      final extras = await _receiptExtrasFor(order);
      final printer = ref.read(printerServiceProvider);
      // #200 / US 33 — same shared derivation as the on-screen reprint, so the
      // paper copy carries the identical Subtotal / Discount / Total.
      final totals = receiptTotalsFromOrder(
        totalAmountKobo: order.totalAmountKobo,
        crateDepositPaidKobo: order.crateDepositPaidKobo,
        discountKobo: order.discountKobo,
      );
      // Built per paper width: the picker fallback below may land on a
      // different printer with a different roll, and rebuilds for it.
      Future<List<int>> buildBytes(ReceiptPaperSize paperSize) =>
          ThermalReceiptService.buildReceipt(
            orderId: order.orderNumber,
            cart: items,
            subtotal: totals.subtotalKobo / 100.0,
            discount: totals.discountKobo / 100.0,
            crateDeposit: totals.depositKobo / 100.0,
            total: totals.totalKobo / 100.0,
            paymentMethod:
                ref.read(payOnDeliveryByOrderProvider)[order.id]?.label ??
                paymentMethodLabel(order.paymentType),
            customerName: _name,
            cashReceived: order.amountPaidKobo / 100.0,
            reprintDate: DateTime.now(),
            orderStatus: order.status,
            refundAmount: order.amountPaidKobo / 100.0,
            storeAddress: storeAddress,
            businessName: ref.read(currentBusinessNameProvider),
            businessPhone: extras.businessPhone,
            businessEmail: extras.businessEmail,
            cashierName: extras.cashierName,
            saleDate: extras.saleDate,
            vatRateBps: extras.vatRateBps,
            vatIncluded: extras.vatIncluded,
            cratesOwedByManufacturer: extras.cratesOwedByManufacturer,
            crateDepositFull: extras.crateDepositFull,
            tracksCrates: businessTracksCrates(
              ref.read(currentBusinessProvider),
            ),
            manufacturerNames: manufacturerNames,
            paperSize: paperSize,
          );

      // Auto-print: reuse the live connection, otherwise auto-connect to the
      // last-used / paired printer, asking once for a new printer's paper
      // width. Only when no printer connects do we fall through to the picker.
      if (!ctx.mounted) return;
      final target = await prepareReceiptPrinter(ctx, printer);
      if (!ctx.mounted) return;
      final bytes = await buildBytes(target.paperSize);
      if (!ctx.mounted) return;
      if (target.connected) {
        final success = await printer.printBytes(bytes);
        if (success) {
          if (!ctx.mounted) return;
          AppNotification.showSuccess(ctx, 'Print successful');
          return;
        }
      }

      if (ctx.mounted) {
        showModalBottomSheet(
          context: ctx,
          isScrollControlled: true,
          backgroundColor: Theme.of(ctx).colorScheme.surface,
          constraints: BoxConstraints(maxHeight: ctx.sheetMaxHeight(0.5)),
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
              final connected = await printer.connect(device.macAdress);
              if (!mounted) return;
              if (connected) {
                if (!ctx.mounted) return;
                // The picked printer may be new (asks once) or use a different
                // roll than the one the bytes were laid out for.
                final picked = await prepareReceiptPrinter(ctx, printer);
                final pickedBytes = picked.paperSize == target.paperSize
                    ? bytes
                    : await buildBytes(picked.paperSize);
                await printer.printBytes(pickedBytes);
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
  bool _showCratesTab() =>
      businessTracksCrates(ref.watch(currentBusinessProvider));

  /// Back (48dp), the title, then — behind the same gate and walk-in guard as
  /// before — Delete, then the live bell. Solid bar: nothing changes on scroll.
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return CustomerTopBar(
      key: CustomersKeys.detailTopBar,
      height: customerTopBarHeight(context),
      header: ScreenHeader(
        icon: AppIcons.user,
        title: 'Customer Profile',
        subtitle: 'Account Details',
        leading: CustomerBarAction(
          key: CustomersKeys.detailBack,
          icon: AppIcons.arrowBackIosNew,
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // §18.4 — soft-delete, CEO/Manager only (customers.delete). Never
          // for the synthetic walk-in (its id is non-null Customer.walkInId).
          if (_customerId != null &&
              _customerId != Customer.walkInId &&
              Gates.deleteCustomer.allows(ref))
            CustomerBarAction(
              key: CustomersKeys.detailDelete,
              icon: AppIcons.delete,
              tooltip: 'Delete customer',
              color: _fixed.danger,
              onPressed: _confirmAndDelete,
            ),
          const CustomerLiveBell(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    final showCrates = _showCratesTab();
    _syncTabController(_resolveTabKeys(showCrates));

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(context),
        // Sideways, the system bar sits on the right: keep the cards out of
        // it (the lists add the bottom inset themselves).
        body: SafeArea(
          top: false,
          bottom: false,
          child: AppRefreshWrapper(
            onRefresh: () => _loadData(),
            child: _contentReady
                ? _buildContent(theme, showCrates)
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, bool showCrates) {
    return TabbedSliverScaffold(
      controller: _tabController,
      tabBarExtent: max(kMinInteractiveDimension, context.getRSize(60)),
      // The hairline under the tab bar is reserved on top of the extent.
      tabBarChromeExtent: 1,
      headerSlivers: [
        CustomerHeaderSliver(
          profile: _buildHeader(theme),
          credits: _buildCreditCard(theme),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
      tabBar: _buildTabBar(theme, showCrates),
      tabViews: [
        TabSliverView(
          storageKey: 'customer-detail-credits',
          slivers: _creditHistoryTabSlivers(theme),
        ),
        TabSliverView(
          storageKey: 'customer-detail-orders',
          slivers: _ordersTabSlivers(theme),
        ),
        if (showCrates)
          TabSliverView(
            storageKey: 'customer-detail-crates',
            slivers: _cratesTabSlivers(theme),
          ),
      ],
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _buildHeader(ThemeData theme) {
    final hasWholesale = !businessSellsOnePrice(
      ref.watch(currentBusinessProvider),
    );
    return CustomerProfileCard(
      showTier: hasWholesale,
      initials: _initials(_name),
      name: _name,
      wholesaler: _groupName == 'wholesaler',
      phone: _phone,
      address: _address,
      since: 'Since ${DateFormat('MMM yyyy').format(_joinedAt)}',
      onEdit:
          _customerId != null &&
              _customerId != Customer.walkInId &&
              Gates.editCustomer.allows(ref)
          ? _openEditSheet
          : null,
    );
  }

  // ── Credit Balance Card ─────────────────────────────────────────────────────

  Widget _buildPeriodPicker() {
    return SizedBox(
      width: context.getRSize(110),
      child: AppDropdown<String>(
        value: _effectivePeriod.startsWith('Custom:')
            ? 'Custom'
            : _effectivePeriod,
        isExpanded: false,
        contentPadding: EdgeInsets.symmetric(
          horizontal: context.getRSize(8),
          vertical: context.getRSize(6),
        ),
        items: _periodOptions
            .map((p) => DropdownMenuItem(value: p, child: Text(p)))
            .toList(),
        onChanged: (v) async {
          if (v == 'Custom') {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              initialDateRange: _customRange,
              builder: (context, child) =>
                  Theme(data: Theme.of(context), child: child!),
            );
            if (range != null) {
              setState(() {
                _customRange = range;
                _selectedPeriod =
                    'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
              });
            }
          } else if (v != null) {
            setState(() {
              _selectedPeriod = v;
              _customRange = null;
            });
          }
        },
      ),
    );
  }

  Widget _buildCreditCard(ThemeData theme) {
    final balance = _creditBalance / 100.0;
    final limit = _limitKobo / 100.0;
    final canAddFunds = Gates.addCustomerCredit.allows(ref);
    final canSetLimit = Gates.setDebtLimit.allows(ref);
    final canRefund = Gates.refundCustomerWallet.allows(ref);
    return CustomerCreditsCard(
      balanceLabel: formatCurrency(balance),
      owes: balance < 0,
      periodPicker: _buildPeriodPicker(),
      limitLabel: limit > 0 ? formatCurrency(limit) : 'No limit',
      depositLabel: _depositsHeld != 0
          ? formatCurrency(_depositsHeld / 100.0)
          : null,
      onAddCredit: canAddFunds ? _showAddFundsSheet : null,
      onSetLimit: canSetLimit ? _showSetLimitSheet : null,
      onRefund: canRefund ? _showRefundCashSheet : null,
    );
  }

  // ── Tab Bar ─────────────────────────────────────────────────────────────────

  Widget _buildTabBar(ThemeData theme, bool showCrates) {
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return LayoutBuilder(
      builder: (context, c) {
        final g = customerDetailGutter(context, c.maxWidth);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: theme.dividerColor, width: 1),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: g),
            child: TabBar(
              controller: _tabController,
              labelColor: theme.colorScheme.primary,
              unselectedLabelColor: muted,
              indicatorColor: theme.colorScheme.primary,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              labelStyle: context.boldStyle(13),
              unselectedLabelStyle: context.semiBoldStyle(13),
              tabs: [
                const Tab(
                  icon: Icon(AppIcons.history, size: 16),
                  text: 'Credits',
                ),
                const Tab(
                  icon: Icon(AppIcons.document, size: 16),
                  text: 'Orders',
                ),
                if (showCrates)
                  const Tab(icon: Icon(AppIcons.box, size: 16), text: 'Crates'),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Wallet Summary ──────────────────────────────────────────────────────────

  Widget _buildCreditSummaryRow(ThemeData theme) {
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
    return Row(
      children: [
        Expanded(
          child: CustomerFigureCard(
            label: 'Total In',
            value: formatCurrency(totalInKobo / 100.0),
            color: _fixed.green,
          ),
        ),
        SizedBox(width: context.getRSize(10)),
        Expanded(
          child: CustomerFigureCard(
            label: 'Total Out',
            value: formatCurrency(totalOutKobo / 100.0),
            color: _fixed.danger,
          ),
        ),
      ],
    );
  }

  // ── Tab: Credit History ─────────────────────────────────────────────────────

  List<Widget> _creditHistoryTabSlivers(ThemeData theme) {
    if (_creditHistory.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: CustomerDetailEmpty(
            icon: AppIcons.waiting,
            message: 'No ledger entries yet',
          ),
        ),
      ];
    }

    final filtered = _filteredHistory;
    final slivers = <Widget>[];

    // §18.4: Total In / Total Out are gated by `customers.wallet.totals.view`
    if (Gates.seeWalletTotals.allows(ref)) {
      slivers.add(
        customerDetailSliver(
          SliverToBoxAdapter(child: _buildCreditSummaryRow(theme)),
          top: context.getRSize(12),
        ),
      );
    }

    if (filtered.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: CustomerDetailEmpty(
            icon: AppIcons.clearFilter,
            message: 'No transactions in this period',
          ),
        ),
      );
    } else {
      slivers.add(
        customerDetailSliver(
          SliverList.builder(
            itemCount: filtered.length,
            itemBuilder: (ctx, i) {
              final txn = filtered[i];
              final isCredit = txn.type == 'credit';
              final amount = txn.amountKobo / 100.0;
              final color = isCredit ? _fixed.green : _fixed.danger;
              // #173 — a live cash/transfer top-up can be voided by anyone
              // who can withdraw from the wallet (the sanctioned fix for a
              // mistyped Add Credit). Hide-don't-block: no affordance
              // renders when the gate is denied or the row isn't a live
              // top-up.
              final isVoidableTopup =
                  txn.voidedAt == null &&
                  (txn.referenceType == 'topup_cash' ||
                      txn.referenceType == 'topup_transfer') &&
                  Gates.refundCustomerWallet.allows(ref);
              return Padding(
                key: ValueKey('$kCustomerCreditRowKeyPrefix${txn.id}'),
                padding: EdgeInsets.only(bottom: ctx.getRSize(10)),
                child: CustomerDetailRow(
                  leading: IconTile(
                    icon: isCredit ? AppIcons.arrowDown : AppIcons.arrowUp,
                    tone: isCredit ? IconTileTone.green : IconTileTone.danger,
                    size: 40,
                  ),
                  title: _friendlyRefType(txn.referenceType),
                  subtitle: DateFormat(
                    'd MMM yyyy, h:mm a',
                  ).format(txn.createdAt),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${isCredit ? '+' : '-'}${formatCurrency(amount)}',
                        style: ctx.extraBoldStyle(15).copyWith(color: color),
                      ),
                      if (isVoidableTopup)
                        SizedBox.square(
                          dimension: kMinInteractiveDimension,
                          child: IconButton(
                            key: CustomersKeys.voidTopup(txn.id),
                            padding: EdgeInsets.zero,
                            tooltip: 'Void top-up',
                            icon: AppIcon(
                              AppIcons.undo,
                              size: ctx.getRSize(20),
                              color: _fixed.danger,
                            ),
                            onPressed: () => _confirmVoidTopup(txn),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          top: context.getRSize(12),
          bottom: context.getRSize(20) + context.deviceBottomPadding,
        ),
      );
    }

    return slivers;
  }

  // ── Tab: Orders ─────────────────────────────────────────────────────────────

  List<Widget> _ordersTabSlivers(ThemeData theme) {
    if (_orders.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: CustomerDetailEmpty(
            icon: AppIcons.receipt,
            message: 'No orders placed yet',
          ),
        ),
      ];
    }
    return [
      customerDetailSliver(
        SliverList.builder(
          itemCount: _orders.length,
          itemBuilder: (ctx, i) {
            final order = _orders[i];
            final total = order.totalAmountKobo / 100.0;
            return Padding(
              padding: EdgeInsets.only(bottom: ctx.getRSize(10)),
              child: CustomerDetailRow(
                key: CustomersKeys.orderRow(order.id),
                leading: const IconTile(icon: AppIcons.receipt, size: 40),
                title: '#${order.orderNumber}',
                subtitle: DateFormat('d MMM yyyy').format(order.createdAt),
                onTap: () => _showReceipt(order),
                trailing: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatCurrency(total),
                      style: ctx
                          .extraBoldStyle(14)
                          .copyWith(color: theme.colorScheme.onSurface),
                    ),
                    SizedBox(height: ctx.getRSize(4)),
                    TagPill(
                      label:
                          order.status[0].toUpperCase() +
                          order.status.substring(1),
                      tone: _orderStatusTone(order.status),
                      dense: true,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        top: context.getRSize(12),
        bottom: context.getRSize(20) + context.deviceBottomPadding,
      ),
    ];
  }

  // ── Tab: Crates ─────────────────────────────────────────────────────────────

  List<Widget> _cratesTabSlivers(ThemeData theme) {
    // §13.4 — the top "+" card is the single entry point for recording crates a
    // customer has brought back (replaces the old per-row "+"). Gated on
    // sales.make (the till-side transaction permission); hidden otherwise
    // (rule #7). It shows even when there is no crate activity yet, so a return
    // can be recorded as a credit for a brand the customer doesn't owe.
    final canRecord = Gates.recordCrateReturn.allows(ref);
    final slivers = <Widget>[];

    final topItems = <Widget>[];
    if (canRecord) {
      topItems.add(_buildCrateReturnCard(theme));
      topItems.add(SizedBox(height: context.getRSize(16)));
    }

    if (_crateBalances.isEmpty) {
      if (topItems.isNotEmpty) {
        slivers.add(
          customerDetailSliver(
            SliverToBoxAdapter(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: topItems,
              ),
            ),
            top: context.getRSize(12),
          ),
        );
      }
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(28)),
            child: Center(
              child: Text(
                'No crate activity recorded',
                textAlign: TextAlign.center,
                style: context
                    .semiBoldStyle(13)
                    .copyWith(
                      color:
                          theme.textTheme.bodySmall?.color ??
                          theme.colorScheme.onSurface,
                    ),
              ),
            ),
          ),
        ),
      );
    } else {
      slivers.add(
        customerDetailSliver(
          SliverList(
            delegate: SliverChildListDelegate([
              ...topItems,
              ..._crateBalances.map(
                (entry) => _buildCrateBalanceRow(theme, entry),
              ),
            ]),
          ),
          top: context.getRSize(12),
          bottom: context.getRSize(20) + context.deviceBottomPadding,
        ),
      );
    }
    return slivers;
  }

  // The "+" action row pinned at the top of the Crates tab.
  Widget _buildCrateReturnCard(ThemeData theme) {
    return SettingsRow(
      key: CustomersKeys.recordCrateReturn,
      icon: AppIcons.add,
      tone: IconTileTone.info,
      title: 'Record crate return',
      subtitle: 'Enter crates brought back, by manufacturer',
      onTap: _showRecordCrateReturnSheet,
    );
  }

  // One per-manufacturer balance row (owed / clear / credit).
  Widget _buildCrateBalanceRow(ThemeData theme, CrateBalanceEntry entry) {
    final bal = entry.balance;
    final isOwe = bal > 0;
    final isClear = bal == 0;
    final tone = isClear
        ? IconTileTone.neutral
        : isOwe
        ? IconTileTone.info
        : IconTileTone.green;
    final pillTone = isClear
        ? TagPillTone.neutral
        : isOwe
        ? TagPillTone.info
        : TagPillTone.green;
    final label = isClear
        ? 'Clear'
        : isOwe
        ? '${bal.abs()} crates owed'
        : '${bal.abs()} crates credit';
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: CustomerDetailRow(
        leading: IconTile(icon: AppIcons.box, tone: tone, size: 40),
        title: entry.manufacturerName,
        trailing: TagPill(label: label, tone: pillTone),
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

    await showCustomerSheet<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => CustomerSheetFrame(
          title: 'Record Crate Return',
          subtitle: 'Crates brought back by the customer',
          children: [
            Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppDropdown<String>(
                    value: selectedId,
                    labelText: 'Manufacturer',
                    hintText: 'Select a manufacturer',
                    items: manufacturers
                        .map(
                          (m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setSheetState(() => selectedId = v),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Select a manufacturer'
                        : null,
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  AppInput(
                    key: CustomersKeys.crateQty,
                    controller: qtyCtrl,
                    labelText: 'Crates returned',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim()) ?? 0;
                      if (n <= 0) return 'Enter how many crates came back';
                      return null;
                    },
                  ),
                  SizedBox(height: ctx.getRSize(24)),
                  AppButton(
                    key: CustomersKeys.crateSubmit,
                    text: 'Record Return',
                    icon: AppIcons.check,
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      final mfrId = selectedId!;
                      final qty = int.parse(qtyCtrl.text.trim());
                      final mfrName = manufacturers
                          .firstWhere((m) => m.id == mfrId)
                          .name;
                      final messenger = ScaffoldMessenger.of(context);
                      // Write-boundary re-check (§10.2.1): honor a revoked override.
                      if (!Gates.recordCrateReturn.allowsNow(ref)) {
                        Navigator.pop(ctx);
                        showGateDenied(context, Gates.recordCrateReturn);
                        return;
                      }
                      Navigator.pop(ctx);
                      try {
                        // §16.8.1: credit the empties to the store the customer's
                        // order(s) for this brand were created from, so per-store
                        // balances stay accurate regardless of the active store.
                        // Fall back to the locked store when the customer has no
                        // store-stamped order for the brand.
                        final creditStoreId =
                            await db.orderCrateLinesDao
                                .resolveStoreForCustomerManufacturer(
                                  customerId: id,
                                  manufacturerId: mfrId,
                                ) ??
                            ref.read(lockedStoreProvider).value;
                        await db.inventoryDao.addEmptyCrates(
                          mfrId,
                          qty,
                          storeId: creditStoreId,
                        );
                        await db.cratePoolDao.recordCrateReturnByCustomer(
                          customerId: id,
                          manufacturerId: mfrId,
                          quantity: qty,
                          performedBy: staffId,
                        );
                        // §7.8 — audit the manual crate return (who/when/brand/
                        // count) so it appears in Activity Logs.
                        await db.activityLogDao.logActivity(
                          action: 'crate_return',
                          description:
                              '$qty crate${qty == 1 ? '' : 's'} returned for '
                              '$mfrName',
                          staffId: staffId,
                          storeId: ref.read(lockedStoreProvider).value,
                          entityType: 'customer',
                          entityId: id,
                        );
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              '$qty crate${qty == 1 ? '' : 's'} returned for '
                              '$mfrName',
                            ),
                            backgroundColor: _fixed.green,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
