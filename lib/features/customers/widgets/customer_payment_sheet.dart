import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// Keys for tests.
abstract final class CustomerPaymentSheetKeys {
  static const sheet = Key('customer-payment-sheet');
  static const search = Key('customer-payment-search');
  static const emptyPicker = Key('customer-payment-empty');
  static const pickedCustomer = Key('customer-payment-picked');
  static const change = Key('customer-payment-change');
  static const balance = Key('customer-payment-balance');
  static const payFull = Key('customer-payment-pay-full');
  static const amount = Key('customer-payment-amount');
  static const note = Key('customer-payment-note');
  static const submit = Key('customer-payment-submit');
  static ValueKey<String> pickerRow(String customerId) =>
      ValueKey<String>('customer-payment-row-$customerId');
  static ValueKey<String> method(String method) =>
      ValueKey<String>('customer-payment-method-$method');
}

/// What a customer's spendable balance means for a payment (#362 PR 3,
/// PRD #270 "Payment forms"): they owe us, they hold credit, or neither.
sealed class CustomerBalanceLine {
  const CustomerBalanceLine();

  /// Classifies a spendable balance in kobo (negative = debt). The same
  /// figure as the customer page's Credits Balance card: held crate deposits
  /// are excluded.
  factory CustomerBalanceLine.fromKobo(int balanceKobo) {
    if (balanceKobo < 0) return CustomerOwes(-balanceKobo);
    if (balanceKobo > 0) return CustomerHasCredit(balanceKobo);
    return const CustomerOwesNothing();
  }
}

final class CustomerOwes extends CustomerBalanceLine {
  const CustomerOwes(this.debtKobo);
  final int debtKobo;
}

final class CustomerHasCredit extends CustomerBalanceLine {
  const CustomerHasCredit(this.creditKobo);
  final int creditKobo;
}

final class CustomerOwesNothing extends CustomerBalanceLine {
  const CustomerOwesNothing();
}

/// The one customer payment form (#362 PR 3, PRD #270 "Payment forms").
///
/// Opened with a [customer] (the customer's own page) it goes straight to the
/// form. Opened without one (Home's Record Payment, #362 PR 4) it first shows
/// a searchable picker of the business's customers (name or phone; never the
/// walk-in, never a deleted customer). Once a customer is chosen the form
/// shows their balance ("Owes ₦X" / "Has ₦X credit" / "Nothing owed") and,
/// when they owe, a "Pay full ₦X" shortcut that fills the amount.
///
/// The write path is the customer page's former Add Credit sheet, unchanged:
/// the `customers.wallet.update` re-check at the write boundary, the store
/// stamped from the active write store, and `CustomerService.topUpWallet`. An
/// amount above the debt is allowed and becomes credit.
class CustomerPaymentSheet extends ConsumerStatefulWidget {
  const CustomerPaymentSheet({
    super.key,
    required this.staffId,
    this.customer,
    this.title = defaultTitle,
    this.submitLabel = defaultTitle,
  });

  /// Today's wording on the customer page.
  static const String defaultTitle = 'Add Credit';

  /// The acting staff member the payment is attributed to.
  final String staffId;

  /// Pre-picked customer; null shows the picker first.
  final Customer? customer;

  /// Sheet heading.
  final String title;

  /// The submit button's label.
  final String submitLabel;

  /// Opens the sheet on [context]'s navigator. Does nothing but explain when
  /// there is no signed-in staff member to attribute the payment to.
  static Future<void> show(
    BuildContext context, {
    Customer? customer,
    String title = defaultTitle,
    String submitLabel = defaultTitle,
  }) async {
    // §18 Add Credit — needs the acting staff to attribute the payment.
    final staffId = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(authProvider).currentUser?.id;
    if (staffId == null) {
      AppNotification.showError(
        context,
        'Could not add credit yet — no active session.',
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CustomerPaymentSheet(
        staffId: staffId,
        customer: customer,
        title: title,
        submitLabel: submitLabel,
      ),
    );
  }

  @override
  ConsumerState<CustomerPaymentSheet> createState() =>
      _CustomerPaymentSheetState();
}

class _CustomerPaymentSheetState extends ConsumerState<CustomerPaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _searchCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  late Customer? _picked = widget.customer;
  String _method = 'cash'; // 'cash' | 'transfer'
  String _query = '';

  /// The customer was chosen in this sheet (not handed in), so it may change.
  bool get _canChange => widget.customer == null;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  List<Customer> _matches(List<Customer> all) {
    final q = _query.trim().toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    return [
      for (final c in all)
        if (!c.isWalkIn &&
            (q.isEmpty ||
                c.name.toLowerCase().contains(q) ||
                (c.phone ?? '').toLowerCase().contains(q) ||
                (qDigits.isNotEmpty &&
                    (c.phone ?? '')
                        .replaceAll(RegExp(r'\D'), '')
                        .contains(qDigits))))
          c,
    ];
  }

  void _pick(Customer c) => setState(() {
    _picked = c;
    _amountCtrl.clear();
  });

  void _unpick() => setState(() {
    _picked = null;
    _amountCtrl.clear();
  });

  void _payFull(int debtKobo) {
    _amountCtrl.text = NumberFormat('#,##0.##', 'en_US').format(debtKobo / 100);
  }

  Future<void> _submit(String customerId) async {
    if (!_formKey.currentState!.validate()) return;
    final amount = parseCurrency(_amountCtrl.text);
    final note = _noteCtrl.text.trim();
    final method = _method;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final successColor =
        (Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light)
            .green;
    // Defense-in-depth write-boundary re-check (§10.2.1): the Add Credit
    // entry points are already render-gated on `customers.wallet.update`
    // (Gates.addCustomerCredit), but re-check the effective permission
    // before moving money so a revoked override is honored at the action too.
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('customers.wallet.update')) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('You don\'t have permission to do that.')),
      );
      return;
    }
    // PRD #155 US 36 — every new payment row carries the store it happened
    // at, resolved the same way an expense (§20.8) and a POS sale resolve it.
    final storeId = ref.read(activeWriteStoreProvider).id;
    final service = ref.read(customerServiceProvider);
    final staffId = widget.staffId;
    navigator.pop();
    try {
      await service.topUpWallet(
        customerId: customerId,
        amountKobo: (amount * 100).round(),
        method: method,
        staffId: staffId,
        storeId: storeId,
        note: note.isEmpty ? null : note,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text('${formatCurrency(amount)} added to credit balance'),
          backgroundColor: successColor,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add credit')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    final picked = _picked;
    final customers = ref.watch(customerServiceProvider).value;
    final balances = ref.watch(creditBalancesKoboProvider).valueOrNull;

    final header = <Widget>[
      Center(
        child: Container(
          width: context.getRSize(40),
          height: context.getRSize(4),
          decoration: BoxDecoration(
            color: t.dividerColor,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
          ),
        ),
      ),
      SizedBox(height: context.getRSize(16)),
      Text(
        widget.title,
        style: context.screenTitleStyle.copyWith(
          color: t.colorScheme.onSurface,
        ),
      ),
      SizedBox(height: context.getRSize(2)),
      Text(
        picked == null
            ? 'Choose the customer who paid'
            : 'Add credit for ${picked.name}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.semiBoldStyle(13).copyWith(color: t.colorScheme.primary),
      ),
      SizedBox(height: context.getRSize(16)),
    ];

    final List<Widget> slivers;
    if (picked == null) {
      final matches = _matches(customers);
      final hasAny = customers.any((c) => !c.isWalkIn);
      slivers = [
        SliverList.list(
          children: [
            ...header,
            if (hasAny) ...[
              AppInput(
                key: CustomerPaymentSheetKeys.search,
                controller: _searchCtrl,
                hintText: 'Search name or phone',
                prefixIcon: Icon(AppIcons.search, color: muted),
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v),
              ),
              SizedBox(height: context.getRSize(12)),
            ],
          ],
        ),
        if (matches.isEmpty)
          SliverToBoxAdapter(
            child: _PickerEmpty(
              key: CustomerPaymentSheetKeys.emptyPicker,
              message: hasAny ? 'No customers match' : 'No customers yet',
            ),
          )
        else
          SliverList.separated(
            itemCount: matches.length,
            separatorBuilder: (_, __) => SizedBox(height: context.getRSize(8)),
            itemBuilder: (context, i) {
              final c = matches[i];
              return _CustomerRow(
                key: CustomerPaymentSheetKeys.pickerRow(c.id),
                name: c.name,
                phone: c.phone,
                onTap: () => _pick(c),
              );
            },
          ),
      ];
    } else {
      // Null while the balances load; a customer with no ledger rows is 0.
      final line = balances == null
          ? null
          : CustomerBalanceLine.fromKobo(balances[picked.id] ?? 0);
      slivers = [
        SliverToBoxAdapter(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...header,
                _PickedCustomerCard(
                  key: CustomerPaymentSheetKeys.pickedCustomer,
                  name: picked.name,
                  phone: picked.phone,
                  balance: line,
                  onChange: _canChange ? _unpick : null,
                ),
                if (line case CustomerOwes(:final debtKobo)) ...[
                  SizedBox(height: context.getRSize(10)),
                  AppButton(
                    key: CustomerPaymentSheetKeys.payFull,
                    text: 'Pay full ${formatCurrency(debtKobo / 100)}',
                    icon: AppIcons.checkCircle,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.small,
                    height: kMinInteractiveDimension,
                    onPressed: () => _payFull(debtKobo),
                  ),
                ],
                SizedBox(height: context.getRSize(16)),
                AppInput(
                  key: CustomerPaymentSheetKeys.amount,
                  controller: _amountCtrl,
                  labelText: 'Amount ($activeCurrencySymbol)',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [CurrencyInputFormatter()],
                  validator: (v) {
                    final n = parseCurrency(v ?? '');
                    if (n <= 0) return 'Enter a valid amount';
                    return null;
                  },
                ),
                SizedBox(height: context.getRSize(16)),
                Text(
                  'Payment method',
                  style: context.semiBoldStyle(13).copyWith(color: muted),
                ),
                SizedBox(height: context.getRSize(8)),
                Row(
                  children: [
                    for (final (i, (value, label, icon)) in const [
                      ('cash', 'Cash', AppIcons.cash),
                      ('transfer', 'Bank Transfer', AppIcons.bank),
                    ].indexed) ...[
                      if (i > 0) SizedBox(width: context.getRSize(10)),
                      Expanded(
                        child: _MethodOption(
                          key: CustomerPaymentSheetKeys.method(value),
                          label: label,
                          icon: icon,
                          isSelected: _method == value,
                          onTap: () => setState(() => _method = value),
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: context.getRSize(16)),
                AppInput(
                  key: CustomerPaymentSheetKeys.note,
                  controller: _noteCtrl,
                  labelText: 'Note (optional)',
                  keyboardType: TextInputType.text,
                ),
                SizedBox(height: context.getRSize(24)),
                AppButton(
                  key: CustomerPaymentSheetKeys.submit,
                  text: widget.submitLabel,
                  icon: AppIcons.add,
                  onPressed: () => _submit(picked.id),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    return ConstrainedBox(
      key: CustomerPaymentSheetKeys.sheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: CustomScrollView(
        shrinkWrap: true,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              context.getRSize(12),
              gutter,
              context.getRSize(16) + context.deviceBottomPadding,
            ),
            sliver: SliverMainAxisGroup(slivers: slivers),
          ),
        ],
      ),
    );
  }
}

/// One customer in the picker: user tile, name, phone. The whole card taps.
class _CustomerRow extends StatelessWidget {
  const _CustomerRow({
    super.key,
    required this.name,
    required this.phone,
    required this.onTap,
  });

  final String name;
  final String? phone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final hasPhone = phone != null && phone!.trim().isNotEmpty;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(12),
                vertical: context.getRSize(10),
              ),
              child: Row(
                children: [
                  const IconTile(icon: AppIcons.user, size: 40),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        if (hasPhone)
                          Text(
                            phone!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(12)
                                .copyWith(color: muted),
                          ),
                      ],
                    ),
                  ),
                  Icon(
                    AppIcons.chevronRight,
                    size: context.getRSize(20),
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chosen customer, their balance line and, when picked in the sheet, a
/// "Change" button back to the picker.
class _PickedCustomerCard extends StatelessWidget {
  const _PickedCustomerCard({
    super.key,
    required this.name,
    required this.phone,
    required this.balance,
    required this.onChange,
  });

  final String name;
  final String? phone;

  /// Null while the balance is still loading.
  final CustomerBalanceLine? balance;

  /// Null when the customer was handed in (it cannot change).
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final hasPhone = phone != null && phone!.trim().isNotEmpty;
    final (String, Color)? balanceText = switch (balance) {
      null => null,
      CustomerOwes(:final debtKobo) => (
        'Owes ${formatCurrency(debtKobo / 100)}',
        f.danger,
      ),
      CustomerHasCredit(:final creditKobo) => (
        'Has ${formatCurrency(creditKobo / 100)} credit',
        f.green,
      ),
      CustomerOwesNothing() => ('Nothing owed', muted),
    };
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          context.getRSize(12),
          context.getRSize(10),
          context.getRSize(onChange == null ? 12 : 4),
          context.getRSize(10),
        ),
        child: Row(
          children: [
            const IconTile(icon: AppIcons.user, size: 44),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .boldStyle(15)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  if (hasPhone)
                    Text(
                      phone!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.regularStyle(12).copyWith(color: muted),
                    ),
                  if (balanceText != null) ...[
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      balanceText.$1,
                      key: CustomerPaymentSheetKeys.balance,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .boldStyle(14)
                          .copyWith(color: balanceText.$2),
                    ),
                  ],
                ],
              ),
            ),
            if (onChange != null)
              TextButton(
                key: CustomerPaymentSheetKeys.change,
                style: TextButton.styleFrom(
                  minimumSize: const Size(
                    kMinInteractiveDimension,
                    kMinInteractiveDimension,
                  ),
                ),
                onPressed: onChange,
                child: Text(
                  'Change',
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One payment-method choice: a card with the method's icon and label; the
/// selected one has a primary border and a pale primary fill.
class _MethodOption extends StatelessWidget {
  const _MethodOption({
    super.key,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    final base = AppDecorations.card(context, radius: AppSpacing.borderRadiusM);
    return Semantics(
      selected: isSelected,
      button: true,
      child: DecoratedBox(
        decoration: isSelected
            ? base.copyWith(
                color: Color.alphaBlend(
                  t.extension<AppSchemeColors>()?.primaryTint ??
                      primary.withValues(alpha: 0.12),
                  t.colorScheme.surface,
                ),
                border: Border.all(color: primary, width: 1.5),
              )
            : base,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(12),
                  vertical: context.getRSize(10),
                ),
                child: Row(
                  children: [
                    AppIcon(
                      icon,
                      filled: isSelected,
                      size: context.getRSize(20),
                      color: isSelected ? primary : muted,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(
                              color: isSelected
                                  ? primary
                                  : t.colorScheme.onSurface,
                            ),
                      ),
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
}

/// The picker's empty state: no customers at all, or none matching.
class _PickerEmpty extends StatelessWidget {
  const _PickerEmpty({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(32)),
      child: Column(
        children: [
          const IconTile(
            icon: AppIcons.customers,
            tone: IconTileTone.neutral,
            size: 48,
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.semiBoldStyle(14).copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
