import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// The one "changed since review" marker (#174 / #192).
///
/// Rendered in two places that must not drift apart: on the reconciliation LIST
/// against a Day bucket whose figures moved, and on the day's own cards against
/// each figure that moved. Both are saying the same thing about the same event,
/// so they are the same widget rather than two hand-rolled pills.
///
/// Neutral WARNING treatment, deliberately not the error red a stock mismatch
/// gets: history mutating after a review is a "look again", not a fault. Since
/// the redesign (#413) it is a [TagPill] in the warning tone.
class ChangedSinceReviewBadge extends StatelessWidget {
  const ChangedSinceReviewBadge({super.key, required this.label});

  /// What moved, already formatted — e.g. `Total sales + ₦2,000`, or just
  /// `Changed since review` on the list, where the card breakdown is one tap
  /// away and an amount would only compete with the day's own figures.
  final String label;

  @override
  Widget build(BuildContext context) =>
      TagPill(label: label, tone: TagPillTone.warning, icon: AppIcons.sync);
}
