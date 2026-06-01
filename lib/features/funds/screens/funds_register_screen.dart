import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

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
    final storeId = isCeo ? (_selectedStoreId ?? lockedStoreId) : lockedStoreId;

    final body = storeId == null
        ? const SizedBox.shrink()
        : _buildForStore(context, storeId, isCeo);

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
      return const SizedBox.shrink();
    }

    final isOpen = ref
            .watch(isDayOpenProvider((storeId: storeId, businessDate: today)))
            .valueOrNull ??
        false;

    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.deviceBottomInset),
      children: [
        if (isCeo) ...[
          _storeSelector(storeId),
          const SizedBox(height: 16),
        ],
        isOpen
            ? _openDayBalances(storeId, today, accounts)
            : _openDayForm(storeId, today, accounts),
        const SizedBox(height: 20),
        if (isCeo) _accountsSection(storeId, accounts),
      ],
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
                ? '${_accountLabel(a)} — opening cash (₦)'
                : '${a.name} — opening balance (₦)',
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
                Text(
                  _accountLabel(a),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
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
}
