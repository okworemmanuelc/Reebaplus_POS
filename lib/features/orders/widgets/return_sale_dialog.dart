import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// One sold line, as the Return dialog shows it (#551).
class ReturnLineInput {
  final String lineId;
  final String name;
  final int quantity;

  /// False for a Quick Sale line (no product): shown without a stepper.
  final bool canBeDamaged;

  const ReturnLineInput({
    required this.lineId,
    required this.name,
    required this.quantity,
    required this.canBeDamaged,
  });
}

/// What the Return dialog collected. The dialog performs no writes.
class ReturnSaleInput {
  final String reason;
  final String damageReasonKey;

  /// Keyed by order-item id; only lines with a damaged quantity above 0.
  final Map<String, int> damagedQtyByLine;

  const ReturnSaleInput({
    required this.reason,
    required this.damageReasonKey,
    required this.damagedQtyByLine,
  });
}

const _damageReasons = <String, String>{
  'broken': 'Broken',
  'expired': 'Expired',
  'spilled': 'Spilled',
  'other': 'Other',
};

/// #551 — collects the reason and per-line damaged counts for a Return.
/// Scrollable AlertDialog so the reason box stays reachable with the keyboard.
Future<ReturnSaleInput?> showReturnSaleDialog(
  BuildContext context, {
  required String orderNumber,
  required String refundLabel,
  required List<ReturnLineInput> lines,
}) {
  return showDialog<ReturnSaleInput>(
    context: context,
    builder: (_) => _ReturnSaleDialog(
      orderNumber: orderNumber,
      refundLabel: refundLabel,
      lines: lines,
    ),
  );
}

class _ReturnSaleDialog extends StatefulWidget {
  final String orderNumber;
  final String refundLabel;
  final List<ReturnLineInput> lines;

  const _ReturnSaleDialog({
    required this.orderNumber,
    required this.refundLabel,
    required this.lines,
  });

  @override
  State<_ReturnSaleDialog> createState() => _ReturnSaleDialogState();
}

class _ReturnSaleDialogState extends State<_ReturnSaleDialog> {
  final _reason = TextEditingController();
  final _damaged = <String, int>{};
  String _damageKey = 'broken';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _anyDamaged => _damaged.values.any((v) => v > 0);

  void _step(ReturnLineInput l, int by) => setState(() {
    final next = ((_damaged[l.lineId] ?? 0) + by).clamp(0, l.quantity);
    _damaged[l.lineId] = next;
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reason = _reason.text.trim();
    return AlertDialog(
      scrollable: true,
      title: Text(
        'Return ${widget.orderNumber}',
        style: context.screenTitleStyle.copyWith(color: cs.onSurface),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The whole sale is reversed and ${widget.refundLabel} goes back '
            'the way it was paid. Stock is restored; mark anything that came '
            'back damaged below and it is written off.',
            style: context.regularStyle(13).copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.getRSize(16)),
          AppInput(
            key: const Key('orders-return-reason'),
            controller: _reason,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            labelText: 'Reason (required)',
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            'Damaged on return',
            style: context.regularStyle(13).copyWith(color: cs.onSurface),
          ),
          for (final l in widget.lines)
            Padding(
              padding: EdgeInsets.only(top: context.getRSize(8)),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${l.quantity} × ${l.name}',
                      style: context.regularStyle(13).copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  if (l.canBeDamaged) ...[
                    IconButton(
                      key: Key('return-dec-${l.lineId}'),
                      icon: const Icon(AppIcons.removeCircle),
                      onPressed: (_damaged[l.lineId] ?? 0) > 0
                          ? () => _step(l, -1)
                          : null,
                    ),
                    Text('${_damaged[l.lineId] ?? 0}'),
                    IconButton(
                      key: Key('return-inc-${l.lineId}'),
                      icon: const Icon(AppIcons.addCircle),
                      onPressed: (_damaged[l.lineId] ?? 0) < l.quantity
                          ? () => _step(l, 1)
                          : null,
                    ),
                  ],
                ],
              ),
            ),
          if (_anyDamaged) ...[
            SizedBox(height: context.getRSize(16)),
            AppDropdown<String>(
              key: const Key('orders-return-damage-reason'),
              value: _damageKey,
              labelText: 'Damage reason',
              items: [
                for (final e in _damageReasons.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _damageKey = v ?? _damageKey),
            ),
          ],
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
          text: 'Return sale',
          icon: AppIcons.refresh,
          variant: AppButtonVariant.danger,
          isFullWidth: false,
          onPressed: reason.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  ReturnSaleInput(
                    reason: reason,
                    damageReasonKey: _damageKey,
                    damagedQtyByLine: {
                      for (final e in _damaged.entries)
                        if (e.value > 0) e.key: e.value,
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
