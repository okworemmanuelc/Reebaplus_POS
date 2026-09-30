import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The "This is what will be recorded" box every crate action sheet shows
/// before saving (PRD #284 §2).
class CrateSheetRecordedLine extends StatelessWidget {
  const CrateSheetRecordedLine({super.key, required this.text, this.textKey});

  /// What will be recorded, or what is still missing.
  final String text;

  /// Key on the text itself, so tests can read the line.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(context.radiusM),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This is what will be recorded',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(text, key: textKey, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
