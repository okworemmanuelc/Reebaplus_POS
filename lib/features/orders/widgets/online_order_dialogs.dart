import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Asks why the shop declines; returns the words the Shopper will see, or
/// null when cancelled. "Other" needs typed text.
Future<String?> showDeclineReasonDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _DeclineReasonDialog(),
  );
}

class _DeclineReasonDialog extends StatefulWidget {
  const _DeclineReasonDialog();

  @override
  State<_DeclineReasonDialog> createState() => _DeclineReasonDialogState();
}

class _DeclineReasonDialogState extends State<_DeclineReasonDialog> {
  OnlineOrderDeclineReason _reason = OnlineOrderDeclineReason.outOfStock;
  final TextEditingController _other = TextEditingController();

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  String? get _answer {
    if (_reason != OnlineOrderDeclineReason.other) return _reason.label;
    final typed = _other.text.trim();
    return typed.isEmpty ? null : typed;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      // Scrolls so the "Other" box stays reachable with the keyboard open.
      scrollable: true,
      title: Text(
        'Decline order',
        style: context.screenTitleStyle.copyWith(color: t.colorScheme.onSurface),
      ),
      content: RadioGroup<OnlineOrderDeclineReason>(
        groupValue: _reason,
        onChanged: (v) => setState(() => _reason = v ?? _reason),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The customer will see this reason.',
              style: t.textTheme.bodyMedium,
            ),
            for (final r in OnlineOrderDeclineReason.values)
              RadioListTile<OnlineOrderDeclineReason>(
                contentPadding: EdgeInsets.zero,
                value: r,
                title: Text(r.label, style: t.textTheme.bodyMedium),
              ),
            if (_reason == OnlineOrderDeclineReason.other)
              AppInput(
                key: OnlineOrderKeys.declineOther,
                controller: _other,
                labelText: 'Reason',
                hintText: 'Tell the customer why',
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                onChanged: (_) => setState(() {}),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(kOnlineOrderReasonMaxLength),
                ],
              ),
          ],
        ),
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: OnlineOrderKeys.declineConfirm,
          text: 'Decline',
          variant: AppButtonVariant.danger,
          isFullWidth: false,
          onPressed: _answer == null
              ? null
              : () => Navigator.pop(context, _answer),
        ),
      ],
    );
  }
}

/// Asks why the shop cancels an ACCEPTED order (#428); returns the words the
/// Shopper will see, or null when dismissed.
Future<String?> showCancelAcceptedDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _CancelAcceptedDialog(),
  );
}

class _CancelAcceptedDialog extends StatefulWidget {
  const _CancelAcceptedDialog();

  @override
  State<_CancelAcceptedDialog> createState() => _CancelAcceptedDialogState();
}

class _CancelAcceptedDialogState extends State<_CancelAcceptedDialog> {
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final typed = _reason.text.trim();
    return AlertDialog(
      // Scrolls so the reason box stays reachable with the keyboard open.
      scrollable: true,
      title: Text(
        'Cancel order',
        style: context.screenTitleStyle.copyWith(color: t.colorScheme.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The customer will see this reason.',
            style: t.textTheme.bodyMedium,
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: OnlineOrderKeys.cancelReason,
            controller: _reason,
            labelText: 'Reason',
            hintText: 'Tell the customer why',
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            onChanged: (_) => setState(() {}),
            inputFormatters: [
              LengthLimitingTextInputFormatter(kOnlineOrderReasonMaxLength),
            ],
          ),
        ],
      ),
      actions: [
        AppButton(
          text: 'Keep order',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: OnlineOrderKeys.cancelConfirm,
          text: 'Cancel order',
          variant: AppButtonVariant.danger,
          isFullWidth: false,
          onPressed: typed.isEmpty ? null : () => Navigator.pop(context, typed),
        ),
      ],
    );
  }
}

/// Asks, on a Shopper's first order here, whether they are a Customer the
/// shop already has. [suggestions] come first (phone match, then name);
/// [search] looks through every not-yet-linked Customer. Returns null when
/// cancelled. Never decided by the app (ADR 0030).
Future<CustomerLinkChoice?> showLinkCustomerDialog(
  BuildContext context, {
  required String shopperName,
  required List<CustomerData> suggestions,
  required Future<List<CustomerData>> Function(String query) search,
}) {
  return showDialog<CustomerLinkChoice>(
    context: context,
    builder: (_) => _LinkCustomerDialog(
      shopperName: shopperName,
      suggestions: suggestions,
      search: search,
    ),
  );
}

class _LinkCustomerDialog extends StatefulWidget {
  const _LinkCustomerDialog({
    required this.shopperName,
    required this.suggestions,
    required this.search,
  });

  final String shopperName;
  final List<CustomerData> suggestions;
  final Future<List<CustomerData>> Function(String query) search;

  @override
  State<_LinkCustomerDialog> createState() => _LinkCustomerDialogState();
}

class _LinkCustomerDialogState extends State<_LinkCustomerDialog> {
  final TextEditingController _query = TextEditingController();
  late List<CustomerData> _shown = widget.suggestions;
  int _searchSeq = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _onSearch(String value) async {
    final seq = ++_searchSeq;
    final found = value.trim().isEmpty
        ? widget.suggestions
        : await widget.search(value);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _shown = found);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return AlertDialog(
      // Scrolls so the search box stays reachable with the keyboard open.
      scrollable: true,
      title: Text(
        'First order from ${widget.shopperName}',
        style: context.screenTitleStyle.copyWith(color: t.colorScheme.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Is this a customer you already have? Later orders from them '
            'will go to the same customer.',
            style: t.textTheme.bodyMedium,
          ),
          SizedBox(height: context.getRSize(12)),
          AppInput(
            key: OnlineOrderKeys.linkSearch,
            controller: _query,
            hintText: 'Search your customers',
            prefixIcon: const Icon(AppIcons.personSearch),
            onChanged: _onSearch,
          ),
          SizedBox(height: context.getRSize(8)),
          if (_shown.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
              child: Text(
                'No matching customers.',
                style: t.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          for (final c in _shown)
            ListTile(
              key: OnlineOrderKeys.linkCustomer(c.id),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.user),
              title: Text(c.name, style: t.textTheme.bodyMedium),
              subtitle: c.phone == null
                  ? null
                  : Text(
                      c.phone!,
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
              onTap: () => Navigator.pop(context, LinkExistingCustomer(c.id)),
            ),
        ],
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: OnlineOrderKeys.linkNew,
          text: 'New customer',
          icon: AppIcons.userAdd,
          isFullWidth: false,
          onPressed: () =>
              Navigator.pop(context, const CreateRetailerCustomer()),
        ),
      ],
    );
  }
}
