import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// One sold line, as the Return dialog shows it (#551).
class ReturnLineInput {
  final String lineId;
  final String name;
  final double quantity;

  /// Units that can still come back ("up to N"): the quantity sold minus what
  /// earlier part returns already took (#712). Null = all of [quantity].
  final double? returnable;

  /// False for a Quick Sale line (no product): shown without a stepper.
  final bool canBeDamaged;

  /// Goods added by an edit in this row, with their price (#732).
  final String? addedNote;

  const ReturnLineInput({
    required this.lineId,
    required this.name,
    required this.quantity,
    required this.canBeDamaged,
    this.returnable,
    this.addedNote,
  });

  double get upTo => returnable ?? quantity;
}

/// What the Return dialog collected. The dialog performs no writes.
class ReturnSaleInput {
  final String reason;
  final String damageReasonKey;

  /// Keyed by order-item id; only lines with a damaged quantity above 0.
  final Map<String, double> damagedQtyByLine;

  /// Keyed by order-item id; only lines with a quantity above 0 (#712).
  final Map<String, double> returnQtyByLine;

  /// True when every unit still returnable comes back: the sale is reversed
  /// whole (and, with no earlier part return, through the full Return).
  final bool returnsEverythingLeft;

  const ReturnSaleInput({
    required this.reason,
    required this.damageReasonKey,
    required this.damagedQtyByLine,
    this.returnQtyByLine = const {},
    this.returnsEverythingLeft = true,
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
  List<ReturnEmpties> emptiesToHandBack = const [],
}) {
  return showDialog<ReturnSaleInput>(
    context: context,
    builder: (_) => _ReturnSaleDialog(
      orderNumber: orderNumber,
      refundLabel: refundLabel,
      lines: lines,
      emptiesToHandBack: emptiesToHandBack,
    ),
  );
}

class _ReturnSaleDialog extends StatefulWidget {
  final String orderNumber;
  final String refundLabel;
  final List<ReturnLineInput> lines;
  final List<ReturnEmpties> emptiesToHandBack;

  const _ReturnSaleDialog({
    required this.orderNumber,
    required this.refundLabel,
    required this.lines,
    required this.emptiesToHandBack,
  });

  @override
  State<_ReturnSaleDialog> createState() => _ReturnSaleDialogState();
}

class _ReturnSaleDialogState extends State<_ReturnSaleDialog> {
  final _reason = TextEditingController();
  final _damaged = <String, double>{};
  late final Map<String, double> _return = {
    for (final l in widget.lines) l.lineId: l.upTo,
  };
  String _damageKey = 'broken';

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _anyDamaged => _damaged.values.any((v) => v > 0);

  void _step(ReturnLineInput l, int by) => setState(() {
    final max = _return[l.lineId] ?? 0;
    final next = ((_damaged[l.lineId] ?? 0) + by).clamp(0.0, max);
    _damaged[l.lineId] = next;
  });

  void _stepReturn(ReturnLineInput l, int by) => setState(() {
    final next = ((_return[l.lineId] ?? 0) + by).clamp(0.0, l.upTo);
    _return[l.lineId] = next;
    // Damaged can never exceed what comes back.
    if ((_damaged[l.lineId] ?? 0) > next) _damaged[l.lineId] = next;
  });

  bool get _anyReturned => _return.values.any((v) => v > 0);

  bool get _everythingLeft => widget.lines.every(
    (l) => (_return[l.lineId] ?? 0) == l.upTo,
  );

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
            _everythingLeft
                ? 'The whole sale is reversed and ${widget.refundLabel} goes '
                      'back the way it was paid. Stock is restored; mark '
                      'anything that came back damaged below and it is '
                      'written off.'
                : 'Only what you pick below comes back. Stock for those items '
                      'is restored and their money goes back the way it was '
                      'paid. The rest of the sale stays as it was.',
            style: context.regularStyle(13).copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          if (widget.emptiesToHandBack.isNotEmpty) ...[
            SizedBox(height: context.getRSize(12)),
            Text(
              'Give the customer back their empties:',
              key: const Key('orders-return-empties'),
              style: context.regularStyle(13).copyWith(color: cs.onSurface),
            ),
            for (final e in widget.emptiesToHandBack)
              Text(
                '${formatQty(e.crates)} ${e.brandName} '
                '${e.crates == 1 ? 'crate' : 'crates'}',
                style: context.regularStyle(13).copyWith(color: cs.onSurface),
              ),
          ],
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
            'What comes back',
            style: context.regularStyle(13).copyWith(color: cs.onSurface),
          ),
          for (final l in widget.lines)
            if (l.upTo > 0)
              Padding(
                padding: EdgeInsets.only(top: context.getRSize(8)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l.name} (up to ${formatQty(l.upTo)})',
                            style: context.regularStyle(13).copyWith(
                              color: cs.onSurface,
                            ),
                          ),
                          if (l.addedNote != null)
                            Text(
                              l.addedNote!,
                              style: context.regularStyle(12).copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: Key('return-qty-dec-${l.lineId}'),
                      icon: const Icon(AppIcons.removeCircle),
                      onPressed: (_return[l.lineId] ?? 0) > 0
                          ? () => _stepReturn(l, -1)
                          : null,
                    ),
                    Text(formatQty(_return[l.lineId] ?? 0)),
                    IconButton(
                      key: Key('return-qty-inc-${l.lineId}'),
                      icon: const Icon(AppIcons.addCircle),
                      onPressed: (_return[l.lineId] ?? 0) < l.upTo
                          ? () => _stepReturn(l, 1)
                          : null,
                    ),
                  ],
                ),
              ),
          SizedBox(height: context.getRSize(16)),
          Text(
            'Damaged on return',
            style: context.regularStyle(13).copyWith(color: cs.onSurface),
          ),
          for (final l in widget.lines)
            if (l.canBeDamaged && (_return[l.lineId] ?? 0) > 0)
              Padding(
                padding: EdgeInsets.only(top: context.getRSize(8)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${formatQty(_return[l.lineId] ?? 0)} × ${l.name}',
                        style: context.regularStyle(13).copyWith(
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      key: Key('return-dec-${l.lineId}'),
                      icon: const Icon(AppIcons.removeCircle),
                      onPressed: (_damaged[l.lineId] ?? 0) > 0
                          ? () => _step(l, -1)
                          : null,
                    ),
                    Text(formatQty(_damaged[l.lineId] ?? 0)),
                    IconButton(
                      key: Key('return-inc-${l.lineId}'),
                      icon: const Icon(AppIcons.addCircle),
                      onPressed:
                          (_damaged[l.lineId] ?? 0) < (_return[l.lineId] ?? 0)
                          ? () => _step(l, 1)
                          : null,
                    ),
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
          text: _everythingLeft ? 'Return sale' : 'Return items',
          icon: AppIcons.refresh,
          variant: AppButtonVariant.danger,
          isFullWidth: false,
          onPressed: reason.isEmpty || !_anyReturned
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
                    returnQtyByLine: {
                      for (final e in _return.entries)
                        if (e.value > 0) e.key: e.value,
                    },
                    returnsEverythingLeft: _everythingLeft,
                  ),
                ),
        ),
      ],
    );
  }
}
