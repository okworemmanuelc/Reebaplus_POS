import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Keys for tests (#710).
abstract final class RefundDestinationKeys {
  static const dialog = Key('refund-destination-dialog');
  static const balance = Key('refund-destination-balance');
  static const cash = Key('refund-destination-cash');
  static const transfer = Key('refund-destination-transfer');
  static const confirm = Key('refund-destination-confirm');
}

/// What the cashier picked: where the refunded money goes. [method] is
/// 'cash' / 'transfer' for [RefundDestination.cashOrTransfer], null for the
/// balance.
class RefundChoice {
  const RefundChoice(this.destination, this.method);
  final RefundDestination destination;
  final String? method;
}

/// #710 — the one Refund destination pop-up, shared by the Pending-tab Refund
/// and the Completed-tab Return. Asked only when money was actually paid
/// ([paidKobo] > 0); the caller skips it for a pure credit sale. A walk-in
/// ([hasCustomer] false) is only offered cash / transfer. Returns null when
/// dismissed. Performs no writes.
Future<RefundChoice?> showRefundDestinationDialog(
  BuildContext context, {
  required int paidKobo,
  required bool hasCustomer,
}) {
  return showDialog<RefundChoice>(
    context: context,
    builder: (_) =>
        _RefundDestinationDialog(paidKobo: paidKobo, hasCustomer: hasCustomer),
  );
}

enum _Pick { balance, cash, transfer }

class _RefundDestinationDialog extends StatefulWidget {
  const _RefundDestinationDialog({
    required this.paidKobo,
    required this.hasCustomer,
  });

  final int paidKobo;
  final bool hasCustomer;

  @override
  State<_RefundDestinationDialog> createState() =>
      _RefundDestinationDialogState();
}

class _RefundDestinationDialogState extends State<_RefundDestinationDialog> {
  _Pick? _pick;

  Widget _option(_Pick value, Key key, String title, String hint) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: () => setState(() => _pick = value),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(6)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _pick == value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: _pick == value ? cs.primary : cs.onSurfaceVariant,
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.regularStyle(14).copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    hint,
                    style: context.regularStyle(12).copyWith(
                      color: cs.onSurfaceVariant,
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final amount = formatCurrency(widget.paidKobo / 100.0);
    return AlertDialog(
      key: RefundDestinationKeys.dialog,
      scrollable: true,
      title: Text(
        'Where should the money go?',
        style: context.screenTitleStyle.copyWith(color: cs.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The customer paid $amount for this sale.',
            style: context.regularStyle(13).copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          if (widget.hasCustomer)
            _option(
              _Pick.balance,
              RefundDestinationKeys.balance,
              "Add to customer's balance",
              'The $amount stays on their account. No cash leaves the till.',
            ),
          _option(
            _Pick.cash,
            RefundDestinationKeys.cash,
            'Give back cash',
            'The $amount leaves today\'s till as cash.',
          ),
          _option(
            _Pick.transfer,
            RefundDestinationKeys.transfer,
            'Give back by transfer',
            'The $amount goes back to them by transfer.',
          ),
        ],
      ),
      actions: [
        AppButton(
          text: 'Back',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: RefundDestinationKeys.confirm,
          text: 'Continue',
          isFullWidth: false,
          onAsyncPressed: _pick == null
              ? null
              : () async {
                  Navigator.pop(
                    context,
                    switch (_pick!) {
                      _Pick.balance => const RefundChoice(
                        RefundDestination.balance,
                        null,
                      ),
                      _Pick.cash => const RefundChoice(
                        RefundDestination.cashOrTransfer,
                        'cash',
                      ),
                      _Pick.transfer => const RefundChoice(
                        RefundDestination.cashOrTransfer,
                        'transfer',
                      ),
                    },
                  );
                },
        ),
      ],
    );
  }
}
