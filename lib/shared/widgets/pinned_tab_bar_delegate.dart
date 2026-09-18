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
/// 3. **Rebuild predicate**: [shouldRebuild] compares [effectiveExtent] and the
///    child itself. The child must be part of the comparison: every host builds
///    it fresh from screen state (a filter selection, a search field's clear
///    button, the visible tab set), and a predicate that ignores it leaves the
///    pinned header painting the widget it was first given. Comparing child
///    *keys* is not enough either — no host passes a key, so every comparison
///    would be `null == null`. This costs one child rebuild per rebuild of the
///    host screen, which is not a per-frame cost: the predicate runs only when
///    a new delegate instance is installed, not while scrolling.
class PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;

  PinnedTabBarDelegate({
    required this.child,
    this.extent = kMinInteractiveDimension,
  });

  /// For a child that spends part of [extent] on non-interactive decoration —
  /// a bottom margin under the tab bar, say. The margin must come out of the
  /// header's own height rather than the tab bar's, or the floor in
  /// [effectiveExtent] guarantees 48dp of *header* while the control inside it
  /// is still short. Reserves [chromeExtent] on top of the interactive floor.
  ///
  /// Count *every* non-interactive pixel, including a decorated `Container`'s
  /// border: it insets its child by the border width top and bottom. Reserving
  /// only an 8dp margin under a 1dp outline left Supplier Detail's tabs at
  /// 46dp on compact phones (#246).
  PinnedTabBarDelegate.withChrome({
    required this.child,
    required double extent,
    required double chromeExtent,
  }) : extent = math.max(extent, kMinInteractiveDimension + chromeExtent);

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
        oldDelegate.child != child;
  }
}

/// Alias for non-tab pinned headers (e.g. search bar) sharing the same
/// height-forcing and minimum-tap-target semantics.
typedef PinnedHeaderDelegate = PinnedTabBarDelegate;
