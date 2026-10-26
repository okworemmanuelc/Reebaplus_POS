import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/online_orders/pay_on_delivery.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';

/// Keys for tests (#432).
abstract final class MarkPaidKeys {
  static const button = Key('orders-mark-paid');
  static const dialog = Key('mark-paid-dialog');
  static const cash = Key('mark-paid-cash');
  static const transfer = Key('mark-paid-transfer');
  static const confirm = Key('mark-paid-confirm');
}

/// Asks how a Pay on delivery order's money came in; returns 'cash' or
/// 'transfer', or null when dismissed.
Future<String?> showMarkPaidDialog(BuildContext context, int toCollectKobo) {
  return showDialog<String>(
    context: context,
    builder: (_) => _MarkPaidDialog(toCollectKobo: toCollectKobo),
  );
}

class _MarkPaidDialog extends StatefulWidget {
  const _MarkPaidDialog({required this.toCollectKobo});

  final int toCollectKobo;

  @override
  State<_MarkPaidDialog> createState() => _MarkPaidDialogState();
}

class _MarkPaidDialogState extends State<_MarkPaidDialog> {
  String _method = 'cash';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      key: MarkPaidKeys.dialog,
      scrollable: true,
      title: Text(
        'Mark as paid',
        style: context.screenTitleStyle.copyWith(color: t.colorScheme.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Record ${formatCurrency(widget.toCollectKobo / 100.0)} collected '
            'for this Pay on delivery order.',
            style: t.textTheme.bodyMedium,
          ),
          SizedBox(height: context.getRSize(12)),
          Row(
            children: [
              Expanded(
                child: SalesChoiceCard(
                  key: MarkPaidKeys.cash,
                  label: 'Cash',
                  icon: AppIcons.cash,
                  centered: true,
                  selected: _method == 'cash',
                  onTap: () => setState(() => _method = 'cash'),
                ),
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: SalesChoiceCard(
                  key: MarkPaidKeys.transfer,
                  label: 'Transfer',
                  icon: AppIcons.swap,
                  centered: true,
                  selected: _method == 'transfer',
                  onTap: () => setState(() => _method = 'transfer'),
                ),
              ),
            ],
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
          key: MarkPaidKeys.confirm,
          text: 'Mark as paid',
          isFullWidth: false,
          onPressed: () => Navigator.pop(context, _method),
        ),
      ],
    );
  }
}

/// Mark as paid (#432): ask cash or transfer, re-check the permission at the
/// write boundary (the button is hidden without it), then post the Record
/// Payment rows linked to the order.
Future<void> markPayOnDeliveryPaid(
  BuildContext context,
  WidgetRef ref,
  PayOnDeliveryOrder pod,
) async {
  final method = await showMarkPaidDialog(context, pod.outstandingKobo);
  if (method == null || !context.mounted) return;
  if (!Gates.markPayOnDeliveryPaid.allowsNow(ref)) {
    showGateDenied(context, Gates.markPayOnDeliveryPaid);
    return;
  }
  final staffId = ref.read(authProvider).currentUser?.id;
  if (staffId == null) {
    AppNotification.showError(context, 'Could not mark paid — no session.');
    return;
  }
  // The store is stamped exactly as Record Payment stamps it.
  final storeId = ref.read(activeWriteStoreProvider).id;
  try {
    final collected = await ref
        .read(customerServiceProvider)
        .markPayOnDeliveryPaid(
          orderId: pod.orderId,
          method: method,
          staffId: staffId,
          storeId: storeId,
        );
    if (!context.mounted) return;
    AppNotification.showSuccess(
      context,
      collected > 0
          ? '${formatCurrency(collected / 100.0)} collected — order paid'
          : 'This order is already paid',
    );
  } catch (_) {
    if (context.mounted) {
      AppNotification.showError(context, 'Could not mark the order paid');
    }
  }
}
