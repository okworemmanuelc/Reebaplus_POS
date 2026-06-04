import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// Funds Register (master plan §23), Phase 1: Open Day (opening cash per
/// account), account management (CEO), and live per-account balances.
class FundsRegisterScreen extends ConsumerStatefulWidget {
  const FundsRegisterScreen({super.key});

  @override
  ConsumerState<FundsRegisterScreen> createState() =>
      _FundsRegisterScreenState();
}

class _FundsRegisterScreenState extends ConsumerState<FundsRegisterScreen> {
  /// CEO-selected store (Manager/others are pinned to the locked store).
  String? _selectedStoreId;

  /// Opening-cash inputs keyed by account id (for the Open Day form).
  final Map<String, TextEditingController> _opening = {};

  /// The store we last auto-ensured a Cash Till for (so we do it once/store).
  String? _ensuredStore;

  @override
  void dispose() {
    for (final c in _opening.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlFor(String accountId) =>
      _opening.putIfAbsent(accountId, () => TextEditingController());

  String _accountLabel(FundsAccountData a) {
    switch (a.accountType) {
      case 'cash_till':
        return 'Cash Till';
      default:
        return a.name;
    }
  }

  Future<void> _openDay(
    String storeId,
    String businessDate,
    List<FundsAccountData> accounts,
  ) async {
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) return;
    // Defense-in-depth (hard rule #6): re-check at the write boundary in case
    // `funds.open_day` was revoked while the form was open.
    if (!ref.read(currentUserPermissionsProvider).contains('funds.open_day')) {
      return;
    }
    final perAccount = <String, int>{};
    for (final a in accounts) {
      final naira = parseCurrency(_opening[a.id]?.text ?? '');
      perAccount[a.id] = (naira * 100).round();
    }
    try {
      await ref.read(databaseProvider).fundDaysDao.openDay(
            storeId: storeId,
            businessDate: businessDate,
            perAccountOpeningKobo: perAccount,
            performedBy: userId,
          );
      if (mounted) AppNotification.showSuccess(context, 'Day opened');
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not open the day');
      }
    }
  }

  Future<void> _addAccount(String storeId, String accountType) async {
    final isBank = accountType == 'bank';
    final label = isBank ? 'Bank account' : 'POS machine';
    final nameCtrl = TextEditingController();
    final numberCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add $label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppInput(
              controller: nameCtrl,
              autofocus: true,
              labelText: 'Name',
              hintText: isBank ? 'e.g. GTB Main' : 'e.g. POS 1',
            ),
            const SizedBox(height: 12),
            AppInput(
              controller: numberCtrl,
              labelText: isBank ? 'Account number' : 'Terminal ID / number',
              hintText: isBank ? 'e.g. 0123456789' : 'optional',
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Add',
            variant: AppButtonVariant.primary,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final number = numberCtrl.text.trim();
    try {
      await ref.read(databaseProvider).fundsAccountsDao.createAccount(
            storeId: storeId,
            accountType: accountType,
            name: name,
            accountNumber: number.isEmpty ? null : number,
          );
    } catch (e) {
      if (mounted) {
        AppNotification.showError(
          context,
          e is StateError ? e.message : 'Could not add the account',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    // Role guard (hard rule #6): Funds Register is Manager/CEO only.
    if (!hasPermission(ref, 'funds.view') &&
        !hasPermission(ref, 'funds.open_day')) {
      return SharedScaffold(
        activeRoute: 'funds_register',
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Text(
              "You don't have access to the Funds Register.",
              style: TextStyle(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final lockedStoreId = ref.read(navigationProvider).lockedStoreId.value;
    // Bug #1 (secondary): a lone-owner CEO has lockedStoreId == null, which left
    // the screen permanently blank. Fall back to the first store the business
    // owns. allStoresProvider is business-scoped, so it can never surface
    // another business's store on a multi-business device.
    final stores = ref.watch(allStoresProvider).valueOrNull;
    final fallbackStoreId =
        (stores != null && stores.isNotEmpty) ? stores.first.id : null;
    final storeId = isCeo
        ? (_selectedStoreId ?? lockedStoreId ?? fallbackStoreId)
        : (lockedStoreId ?? fallbackStoreId);

    // Bug #1 (primary): show a fade-in placeholder while the store list / async
    // providers resolve instead of a bare SizedBox.shrink() that flashes blank
    // then pops in content (§30.7 — loading is a fade-in, not a blank/spinner).
    final Widget body;
    if (storeId == null) {
      body = stores == null
          ? _loadingState(context)
          : _emptyState(context, "No store found for this business.");
    } else {
      body = _buildForStore(context, storeId, isCeo);
    }

    return SharedScaffold(
      activeRoute: 'funds_register',
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        elevation: 0,
        leading: const MenuButton(),
        title: const AppBarHeader(
          icon: FontAwesomeIcons.vault,
          title: 'Funds Register',
          subtitle: 'Open the day, manage accounts',
        ),
        actions: const [NotificationBell(), SizedBox(width: 8)],
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _buildForStore(BuildContext context, String storeId, bool isCeo) {
    // Ensure a Cash Till exists for this store (once per store).
    if (_ensuredStore != storeId) {
      _ensuredStore = storeId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(databaseProvider).fundsAccountsDao.ensureCashTill(storeId);
      });
    }

    final accountsAsync = ref.watch(fundsAccountsForStoreProvider(storeId));
    final todayAsync = ref.watch(todaysBusinessDateProvider);
    final today = todayAsync.valueOrNull;
    final accounts = accountsAsync.valueOrNull;
    if (today == null || accounts == null) {
      return _loadingState(context); // bug #1 — fade-in, not blank.
    }

    final day = ref
        .watch(fundDayProvider((storeId: storeId, businessDate: today)))
        .valueOrNull;
    final status = day?.status; // null = not opened, 'open', 'closed'.
    // §23.8 — a prior day for this store is still unclosed.
    final unclosed = ref
        .watch(
          unclosedDayBeforeProvider((storeId: storeId, businessDate: today)),
        )
        .valueOrNull;

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.deviceBottomInset),
      children: [
        if (isCeo) ...[
          _storeSelector(storeId),
          const SizedBox(height: 16),
        ],
        if (unclosed != null) ...[
          // §23.8 — must close the previous day before today can open. The
          // banner's action closes that prior day; once closed it clears and
          // today's open-day form appears.
          _unclosedDayBanner(storeId, unclosed, accounts),
          const SizedBox(height: 20),
        ] else ...[
          if (status == 'open')
            _openDayBalances(storeId, today, accounts)
          else if (status == 'closed')
            _closedDaySummary(storeId, today, accounts)
          // Opening the day is gated on `funds.open_day` (hard rule #6). A
          // `funds.view`-only viewer reaches this screen (OR-clause guard) but
          // must not see the open-day form — show a wait note instead.
          else if (hasPermission(ref, 'funds.open_day'))
            _openDayForm(storeId, today, accounts)
          else
            _openDayLockedNote(),
          const SizedBox(height: 20),
        ],
        if (isCeo) _accountsSection(storeId, accounts),
      ],
    );
  }

  /// Fade-in loading placeholder (§30.7 — no spinner) shown while the store
  /// list / day / accounts providers resolve. Bug #1.
  Widget _loadingState(BuildContext context) {
    final theme = Theme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(opacity: v, child: child),
      child: ListView(
        padding:
            EdgeInsets.fromLTRB(20, 20, 20, 20 + context.deviceBottomInset),
        children: [
          _card(
            title: 'Funds Register',
            children: [
              SizedBox(
                height: 100,
                child: Center(
                  child: Text(
                    'Loading…',
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _storeSelector(String storeId) {
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    if (stores.length < 2) return const SizedBox.shrink();
    return AppDropdown<String>(
      value: storeId,
      items: stores
          .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
          .toList(),
      onChanged: (v) => setState(() => _selectedStoreId = v),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _openDayForm(
    String storeId,
    String today,
    List<FundsAccountData> accounts,
  ) {
    return _card(
      title: 'Open the day',
      children: [
        Text(
          'Enter the starting balance for each account, then open the day to '
          'start selling.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 16),
        for (final a in accounts) ...[
          AppInput(
            controller: _ctrlFor(a.id),
            labelText: a.accountType == 'cash_till'
                ? '${_accountLabel(a)} — opening cash ($activeCurrencySymbol)'
                : '${a.name} — opening balance ($activeCurrencySymbol)',
            hintText: '0',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [CurrencyInputFormatter()],
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        AppButton(
          text: 'Open Day',
          variant: AppButtonVariant.primary,
          icon: FontAwesomeIcons.lockOpen,
          onPressed: () => _openDay(storeId, today, accounts),
        ),
      ],
    );
  }

  /// Shown to a `funds.view`-only viewer (no `funds.open_day`) when today's day
  /// isn't open yet — they may watch balances but not open the day (hard rule
  /// #6/#7: no open-day form, no Open Day button).
  Widget _openDayLockedNote() {
    return _card(
      title: 'Day not opened',
      children: [
        Text(
          'The day hasn’t been opened yet. A Manager or CEO needs to open it '
          'before sales can start.',
          style: TextStyle(
            fontSize: 13,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _openDayBalances(
    String storeId,
    String today,
    List<FundsAccountData> accounts,
  ) {
    final balances = ref
            .watch(fundDayBalancesProvider(
                (storeId: storeId, businessDate: today)))
            .valueOrNull ??
        const <String, int>{};
    final theme = Theme.of(context);
    return _card(
      title: "Today's balances",
      children: [
        Row(
          children: [
            Icon(FontAwesomeIcons.circleCheck,
                size: 14, color: Colors.green.shade600),
            const SizedBox(width: 8),
            Text(
              'Day is open',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.green.shade600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        for (final a in accounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _accountLabel(a),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatCurrency((balances[a.id] ?? 0) / 100.0),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        // §23.6 — Close Day. Hidden for roles without funds.close_day
        // (hide-don't-block, hard rule #7).
        if (hasPermission(ref, 'funds.close_day')) ...[
          const SizedBox(height: 16),
          AppButton(
            text: 'Close Day',
            variant: AppButtonVariant.primary,
            icon: FontAwesomeIcons.lock,
            onPressed: () => _showCloseDaySheet(storeId, today, accounts),
          ),
        ],
      ],
    );
  }

  Widget _accountsSection(String storeId, List<FundsAccountData> accounts) {
    final theme = Theme.of(context);
    return _card(
      title: 'Accounts',
      children: [
        for (final a in accounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  a.accountType == 'cash_till'
                      ? FontAwesomeIcons.moneyBill1
                      : a.accountType == 'pos_machine'
                          ? FontAwesomeIcons.creditCard
                          : FontAwesomeIcons.buildingColumns,
                  size: 14,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _accountLabel(a),
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if ((a.accountNumber ?? '').isNotEmpty)
                        Text(
                          a.accountNumber!,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                ),
                // Cash Till is auto-created and not deletable.
                if (a.accountType != 'cash_till')
                  IconButton(
                    tooltip: 'Remove',
                    icon: Icon(Icons.delete_outline,
                        size: 20, color: Colors.red.shade400),
                    onPressed: () => ref
                        .read(databaseProvider)
                        .fundsAccountsDao
                        .softDeleteAccount(a.id),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: AppButton(
                text: 'Add POS',
                variant: AppButtonVariant.outline,
                icon: FontAwesomeIcons.creditCard,
                onPressed: () => _addAccount(storeId, 'pos_machine'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AppButton(
                text: 'Add Bank',
                variant: AppButtonVariant.outline,
                icon: FontAwesomeIcons.buildingColumns,
                onPressed: () => _addAccount(storeId, 'bank'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// §23.8 — a previous day is still open. Big banner with a Close action so the
  /// user can close it (and unblock opening today).
  Widget _unclosedDayBanner(
    String storeId,
    FundDayData unclosed,
    List<FundsAccountData> accounts,
  ) {
    final theme = Theme.of(context);
    final amber = Colors.amber.shade700;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: amber.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FontAwesomeIcons.triangleExclamation, size: 16, color: amber),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Previous day not closed',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The day for ${unclosed.businessDate} is still open. Close it before '
            'starting a new day.',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(height: 14),
          if (hasPermission(ref, 'funds.close_day'))
            AppButton(
              text: 'Close ${unclosed.businessDate}',
              variant: AppButtonVariant.primary,
              icon: FontAwesomeIcons.lock,
              onPressed: () =>
                  _showCloseDaySheet(storeId, unclosed.businessDate, accounts),
            ),
        ],
      ),
    );
  }

  /// §23.6 — the day is closed; show the per-account reconciliation (expected vs
  /// counted, variance flagged in red).
  Widget _closedDaySummary(
    String storeId,
    String today,
    List<FundsAccountData> accounts,
  ) {
    final theme = Theme.of(context);
    final closings = ref
            .watch(fundDayClosingsProvider(
                (storeId: storeId, businessDate: today)))
            .valueOrNull ??
        const <FundDayClosingData>[];
    final labelFor = {for (final a in accounts) a.id: _accountLabel(a)};
    return _card(
      title: "Day closed",
      children: [
        Row(
          children: [
            Icon(FontAwesomeIcons.lock, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Reconciliation',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        for (final c in closings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  labelFor[c.fundsAccountId] ?? c.accountType,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                _summaryLine('Expected', c.expectedKobo, theme),
                _summaryLine('Counted', c.countedKobo, theme),
                _summaryLine(
                  'Variance',
                  c.varianceKobo,
                  theme,
                  danger: c.varianceKobo != 0,
                ),
              ],
            ),
          ),
        if (closings.isEmpty)
          Text(
            'No reconciliation recorded.',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
      ],
    );
  }

  Widget _summaryLine(String label, int kobo, ThemeData theme,
      {bool danger = false}) {
    final color =
        danger ? Colors.red.shade600 : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
          Text(
            formatCurrency(kobo / 100.0),
            style: TextStyle(
              fontSize: 13,
              fontWeight: danger ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCloseDaySheet(
    String storeId,
    String businessDate,
    List<FundsAccountData> accounts,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CloseDaySheet(
        storeId: storeId,
        businessDate: businessDate,
        accounts: accounts,
      ),
    );
  }
}

/// §23.6 Close Day flow — per account, show the expected (live) balance and
/// collect the counted cash (till) / amount withdrawn (POS, bank), then close.
class _CloseDaySheet extends ConsumerStatefulWidget {
  final String storeId;
  final String businessDate;
  final List<FundsAccountData> accounts;

  const _CloseDaySheet({
    required this.storeId,
    required this.businessDate,
    required this.accounts,
  });

  @override
  ConsumerState<_CloseDaySheet> createState() => _CloseDaySheetState();
}

class _CloseDaySheetState extends ConsumerState<_CloseDaySheet> {
  final Map<String, TextEditingController> _counted = {};
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _counted.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlFor(String id) =>
      _counted.putIfAbsent(id, () => TextEditingController());

  String _label(FundsAccountData a) =>
      a.accountType == 'cash_till' ? 'Cash Till' : a.name;

  String _prettyDate(String date) {
    final d = DateTime.tryParse(date);
    return d == null ? date : DateFormat('EEE, d MMM yyyy').format(d);
  }

  Future<void> _close() async {
    if (_saving) return;
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        title: const Text('Close the day?'),
        content: Text(
          'This closes ${_prettyDate(widget.businessDate)} for this store. '
          'You won\'t be able to record more sales for this day, and a new day '
          'must be opened to continue. Make sure the counts above are correct.',
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Close Day',
            variant: AppButtonVariant.primary,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final userId = ref.read(authProvider).currentUser?.id;
    if (userId == null) return;
    setState(() => _saving = true);
    final perAccount = <String, int>{};
    for (final a in widget.accounts) {
      final naira = parseCurrency(_counted[a.id]?.text ?? '');
      perAccount[a.id] = (naira * 100).round();
    }
    try {
      await ref.read(databaseProvider).fundDaysDao.closeDay(
            storeId: widget.storeId,
            businessDate: widget.businessDate,
            perAccountCountedKobo: perAccount,
            performedBy: userId,
          );
      if (mounted) {
        Navigator.pop(context);
        AppNotification.showSuccess(context, 'Day closed');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        AppNotification.showError(
          context,
          e is StateError ? e.message : 'Could not close the day',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balances = ref
            .watch(fundDayBalancesProvider((
          storeId: widget.storeId,
          businessDate: widget.businessDate,
        )))
            .valueOrNull ??
        const <String, int>{};

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        20 + context.deviceBottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Close the day',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Count the cash in the till and enter the amount withdrawn from each '
            'POS / bank account. Differences are flagged for review.',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final a in widget.accounts) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _label(a),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Expected ${formatCurrency((balances[a.id] ?? 0) / 100.0)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    AppInput(
                      controller: _ctrlFor(a.id),
                      labelText: a.accountType == 'cash_till'
                          ? 'Cash counted ($activeCurrencySymbol)'
                          : 'Amount withdrawn ($activeCurrencySymbol)',
                      hintText: '0',
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [CurrencyInputFormatter()],
                    ),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          AppButton(
            text: _saving ? 'Closing…' : 'Confirm Close Day',
            variant: AppButtonVariant.primary,
            icon: FontAwesomeIcons.lock,
            isLoading: _saving,
            onPressed: _saving ? null : _close,
          ),
        ],
      ),
    );
  }
}
