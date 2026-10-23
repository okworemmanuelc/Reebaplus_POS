import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Small progress dots for the sign-up flows (master plan §5: "small dots
/// progress indicator"). Dots up to and including [current] take the accent;
/// the current dot stretches into a pill. Shared by CEO and staff sign-up.
///
/// Theme colours only; sizes scale with `getRSize`.
class SignUpStepDots extends StatelessWidget {
  /// Zero-based index of the current dot.
  final int current;

  /// How many dots to draw.
  final int total;

  const SignUpStepDots({super.key, required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final idle = authTextMuted(context, 0.18);
    final dot = context.getRSize(8);
    final pill = context.getRSize(22);
    return Semantics(
      label: 'Step ${current + 1} of $total',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(total, (i) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: EdgeInsets.symmetric(horizontal: context.getRSize(3)),
              width: i == current ? pill : dot,
              height: dot,
              decoration: BoxDecoration(
                color: i <= current ? primary : idle,
                borderRadius: BorderRadius.circular(dot / 2),
              ),
            );
          }),
        ),
      ),
    );
  }
}
