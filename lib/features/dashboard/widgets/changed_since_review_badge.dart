import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The one "changed since review" marker (#174 / #192).
///
/// Rendered in two places that must not drift apart: on the reconciliation LIST
/// against a Day bucket whose figures moved, and on the day's own cards against
/// each figure that moved. Both are saying the same thing about the same event,
/// so they are the same widget rather than two hand-rolled pills.
///
/// Neutral WARNING treatment, deliberately not the error red a stock mismatch
/// gets: history mutating after a review is a "look again", not a fault.
class ChangedSinceReviewBadge extends StatelessWidget {
  const ChangedSinceReviewBadge({super.key, required this.label});

  /// What moved, already formatted — e.g. `Total sales + ₦2,000`, or just
  /// `Changed since review` on the list, where the card breakdown is one tap
  /// away and an amount would only compete with the day's own figures.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = theme.extension<AppSemanticColors>()!.warning;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: warn.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.arrowsRotate.data, size: 10, color: warn),
          SizedBox(width: context.getRSize(5)),
          // Flexible so a long label + amount ("Net cash movement − ₦2,400,000")
          // shrinks inside its line instead of overflowing it on a narrow phone.
          Flexible(
            child: Text(
              label,
              style: context.bodySmall.copyWith(
                color: warn,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
