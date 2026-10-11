import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/quick_actions.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// Keys for tests.
abstract final class RecordPaymentChooserKeys {
  static const sheet = Key('record-payment-chooser');
  static ValueKey<String> option(PaymentSide side) =>
      ValueKey<String>('record-payment-chooser-${side.name}');
}

/// Home's "Record Payment" chooser (#362 PR 4, PRD #270 "Tile destinations"):
/// "Customer paid us" or "We paid a supplier", modelled on the supplier page's
/// "Record Activity" chooser. Shown only when both [sides] are available (one
/// side skips it). Resolves to the side tapped, or null when dismissed; the
/// caller opens that side's form on its own context, so the form sits on the
/// same navigator as the tile and closing it returns there.
Future<PaymentSide?> showRecordPaymentChooser(
  BuildContext context, {
  required List<PaymentSide> sides,
}) {
  return showModalBottomSheet<PaymentSide>(
    context: context,
    isScrollControlled: true,
    builder: (_) => RecordPaymentChooser(sides: sides),
  );
}

/// The chooser sheet's body: handle, "Record Payment", one option per side.
class RecordPaymentChooser extends StatelessWidget {
  const RecordPaymentChooser({super.key, required this.sides});

  /// The sides to offer, in [PaymentSide] order.
  final List<PaymentSide> sides;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    return ConstrainedBox(
      key: RecordPaymentChooserKeys.sheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(12),
          gutter,
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
              'Record Payment',
              style: context.screenTitleStyle.copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: context.getRSize(2)),
            Text(
              'Who is paying?',
              style: context.semiBoldStyle(13).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(16)),
            for (final (i, side) in sides.indexed) ...[
              if (i > 0) SizedBox(height: context.getRSize(10)),
              _ChooserOption(
                key: RecordPaymentChooserKeys.option(side),
                side: side,
                onTap: () => Navigator.of(context).pop(side),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One option: a fixed-pair icon tile, title, subtitle and chevron. The whole
/// card taps.
class _ChooserOption extends StatelessWidget {
  const _ChooserOption({super.key, required this.side, required this.onTap});

  final PaymentSide side;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // Money coming in is green (as Home's tile); money going out is red (as
    // Add Expense and the Total Expenses card).
    final (icon, tone, title, subtitle) = switch (side) {
      PaymentSide.customer => (
        AppIcons.user,
        IconTileTone.green,
        'Customer paid us',
        'Reduces what they owe',
      ),
      PaymentSide.supplier => (
        AppIcons.supplier,
        IconTileTone.danger,
        'We paid a supplier',
        'Reduces what you owe',
      ),
    };
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  IconTile(icon: icon, tone: tone, size: 44),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
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
