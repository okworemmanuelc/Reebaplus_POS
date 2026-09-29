import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/crates/crate_value_change_impact.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Test keys for [CrateValueChangeSheet] (#295).
const String kCrateValueChangeSheetKey = 'crate_value_change_sheet';
const String kCrateValueChangeConfirmKey = 'crate_value_change_confirm';
const String kCrateValueChangeCancelKey = 'crate_value_change_cancel';

/// The confirmation shown before a crate value change is written (#295, PRD
/// #284 §10): what moves, in naira, and what does not. Resolves `true` only
/// when the owner confirms; backing out (Cancel, swipe, scrim) resolves
/// `false`/null and the caller writes nothing.
class CrateValueChangeSheet extends StatelessWidget {
  const CrateValueChangeSheet({
    super.key,
    required this.brandName,
    required this.impact,
  });

  final String brandName;
  final CrateValueChangeImpact impact;

  static Future<bool> show(
    BuildContext context, {
    required String brandName,
    required CrateValueChangeImpact impact,
  }) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CrateValueChangeSheet(brandName: brandName, impact: impact),
    );
    return confirmed ?? false;
  }

  static String _signed(int kobo) {
    final text = formatCurrency(kobo.abs() / 100);
    if (kobo == 0) return text;
    return kobo > 0 ? '+$text' : '-$text';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final lines = [...impact.statusMoves, ?impact.supplierDebt];
    return Container(
      key: const ValueKey(kCrateValueChangeSheetKey),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(24),
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Change crate value?',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: context.getRSize(4)),
            Text(
              '$brandName: ${formatCurrency(impact.oldKobo / 100)} → '
              '${formatCurrency(impact.newKobo / 100)} per crate',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'What moves',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            if (lines.isEmpty)
              Text(
                'No crates are counted for this brand yet, so no figure moves.',
                style: theme.textTheme.bodyMedium,
              )
            else
              for (final m in lines)
                Padding(
                  padding: EdgeInsets.only(bottom: context.getRSize(4)),
                  child: Text(
                    '${m.label} (${m.count} crates): '
                    '${formatCurrency(m.beforeKobo / 100)} to '
                    '${formatCurrency(m.afterKobo / 100)} '
                    '(${_signed(m.deltaKobo)})',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            SizedBox(height: context.getRSize(4)),
            Text(
              'Daily Reconciliation shows these same crates at the new value '
              '(${_signed(impact.totalDeltaKobo)} in total).',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'What does not move',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Past sales, damages, write-offs and refunds stay at the value '
              'they were recorded at. Customer deposit already paid stays as '
              'paid.',
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              'New sales, including carts already open, charge the new value.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.getRSize(24)),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    key: const ValueKey(kCrateValueChangeCancelKey),
                    text: 'Cancel',
                    variant: AppButtonVariant.outline,
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: AppButton(
                    key: const ValueKey(kCrateValueChangeConfirmKey),
                    text: 'Change value',
                    variant: AppButtonVariant.primary,
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
