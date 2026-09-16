import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A shared [SliverPersistentHeaderDelegate] that pins a tab bar (or header)
/// under a scrolling container, forcing its rendered height and flooring its
/// extent at [kMinInteractiveDimension].
///
/// ### Why this exists (Issue #240 / PRD #239)
///
/// 1. **Height forcing**: Under a `NestedScrollView`, a pinned header reports
///    `paintExtent` from the child's *actual* rendered height but `layoutExtent`
///    from the declared `maxExtent`. If the loosely-constrained child renders
///    even fractionally shorter than `extent`, `paintExtent` drops below
///    `layoutExtent` and trips the framework assertion:
///    `layoutExtent exceeds paintExtent`. Wrapping the child in a `SizedBox`
///    of `effectiveExtent` guarantees `childExtent == maxExtent`.
///
/// 2. **Minimum tap-target floor**: Screens passing a responsive `extent`
///    (e.g. `context.getRSize(60)`) compress down to 42dp at the short-viewport
///    floor (`spacingScale = 0.70`). A tab bar is an interactive control and
///    cannot compact below the 48dp accessibility floor. [effectiveExtent]
///    clamps at [kMinInteractiveDimension].
///
/// 3. **Stable rebuild predicate**: Unlike naive delegates that compare widget
///    instances (`oldDelegate.child != child`), [shouldRebuild] compares
///    [effectiveExtent] and child [Key]s, avoiding spurious rebuilds on every
///    scroll frame.
class PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;

  PinnedTabBarDelegate({
    required this.child,
    this.extent = kMinInteractiveDimension,
  });

  /// The extent floored at Flutter's [kMinInteractiveDimension] (48.0dp).
  double get effectiveExtent => math.max(kMinInteractiveDimension, extent);

  @override
  double get minExtent => effectiveExtent;

  @override
  double get maxExtent => effectiveExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox(
      height: effectiveExtent,
      child: child,
    );
  }

  @override
  bool shouldRebuild(PinnedTabBarDelegate oldDelegate) {
    return oldDelegate.effectiveExtent != effectiveExtent ||
        oldDelegate.child.key != child.key;
  }
}

/// Alias for non-tab pinned headers (e.g. search bar) sharing the same
/// height-forcing and minimum-tap-target semantics.
typedef PinnedHeaderDelegate = PinnedTabBarDelegate;
