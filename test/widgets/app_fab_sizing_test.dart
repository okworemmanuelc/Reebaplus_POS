// app_fab_sizing_test.dart
//
// Regression net for the full-bleed FAB reported 2026-09-15: every labelled
// `AppFAB` in the app — "Add Store", "Add Customer", "Add Expense" and five
// more — painted as a screen-wide bar with its left edge cut off the screen,
// instead of the pill the design system specifies (see `context/ui-context.md`
// → `AppFAB`: min width 165px).
//
// Root cause, introduced by cfd2165 (2026-08-11, the icon-only barcode button
// redesign): the icon + label row was wrapped in a `Center`. A `Center` is an
// `Align` with no `widthFactor`, so it shrink-wraps ONLY when its incoming
// maxWidth is infinite. In the `Scaffold` FAB slot the constraints are loose
// but BOUNDED (0..screenWidth), so the `Center` expanded to fill — dragging the
// whole button out to the full screen width. `endFloat`, the Scaffold default
// that every affected screen relies on, then right-aligned that over-wide box
// and pushed its left edge to -16dp, off the screen.
//
// The icon-only variant escaped because its `Container` gets an explicit
// `width: fabHeight`, whose tight constraints leave the `Center` nothing to
// expand into. That is why one commit could break eight screens while the
// variant it was written for looked fine.
//
// These tests observe only the rendered rect of the public `AppFAB` widget, so
// the fix stays free to restructure the widget's internals.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/widgets/app_fab.dart';

import '../helpers/viewports.dart';

/// Pumps [fab] into the `Scaffold.floatingActionButton` slot — the slot every
/// call site in the app uses — at [size], and returns its rendered rect.
Future<Rect> _pumpFabAt(
  WidgetTester tester, {
  required Size size,
  required Widget fab,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: fab,
      ),
    ),
  );
  return tester.getRect(find.byType(AppFAB));
}

void main() {
  testWidgets('a labelled FAB is a pill that fits on screen', (tester) async {
    const size = pixel7Portrait;

    final rect = await _pumpFabAt(
      tester,
      size: size,
      fab: AppFAB(
        icon: Icons.add_rounded,
        label: 'Add Store',
        onPressed: () {},
      ),
    );

    expect(
      rect.width,
      lessThan(size.width),
      reason: 'the button spans the entire screen width instead of hugging '
          'its icon + label',
    );
    expect(
      rect.left,
      greaterThanOrEqualTo(0),
      reason: 'the button is cut off at the left screen edge',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(size.width),
      reason: 'the button runs past the right screen edge',
    );
  });

  // `phoneMiniPortrait` (375x812) is the responsive baseline: shortestSide is
  // exactly `_kBaseShortestSide` and the height clears the comfort threshold,
  // so the spacing scale is 1.0 and the spec's 165px is literal here (ADR 0025).
  // That keeps the expected value the design system's number rather than one
  // recomputed through `rSize`.
  testWidgets('a short label still honours the 165dp minimum width',
      (tester) async {
    final rect = await _pumpFabAt(
      tester,
      size: phoneMiniPortrait,
      fab: AppFAB(
        icon: Icons.add_rounded,
        label: 'Add',
        onPressed: () {},
      ),
    );

    expect(
      rect.width,
      closeTo(165, 0.5),
      reason: 'an icon + "Add" is far narrower than 165dp, so the design '
          'system floor should be setting the width',
    );
  });

  // The variant cfd2165 was written for. It escaped the full-bleed bug, so this
  // guards the fix rather than the defect: shrink-wrapping the shared `Center`
  // must not collapse the square button down onto its icon.
  testWidgets('an icon-only FAB stays square', (tester) async {
    final rect = await _pumpFabAt(
      tester,
      size: phoneMiniPortrait,
      fab: AppFAB(
        icon: Icons.qr_code_scanner,
        onPressed: () {},
      ),
    );

    expect(
      rect.width,
      closeTo(rect.height, 0.01),
      reason: 'the icon-only button is no longer square',
    );
  });
}
