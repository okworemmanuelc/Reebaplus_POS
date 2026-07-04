// speed_dial_fab_test.dart
//
// The Add Product / Receive Stock speed dial (issue #33 / ADR 0006). The widget
// is permission-agnostic — callers gate-filter the actions and hand it only the
// survivors — so these tests drive the collapse contract directly: zero actions
// render no FAB, exactly one renders a direct FAB (never a menu of one), and two
// or more render the expandable dial with labelled, described options.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/core/widgets/app_speed_dial_fab.dart';

Widget _host(List<AppSpeedDialAction> actions) {
  return MaterialApp(
    home: Scaffold(
      floatingActionButton: AppSpeedDialFab(
        actions: actions,
        reserveBottomInset: false,
      ),
    ),
  );
}

void main() {
  group('AppSpeedDialFab collapse', () {
    testWidgets('no actions renders no FAB', (tester) async {
      await tester.pumpWidget(_host(const []));

      expect(find.byType(AppFAB), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.text('Add Product'), findsNothing);
      expect(find.text('Receive Stock'), findsNothing);
    });

    testWidgets('one action renders a direct FAB, not a menu of one',
        (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_host([
        AppSpeedDialAction(
          icon: Icons.local_shipping,
          label: 'Receive Stock',
          description: 'Log a delivery from a supplier',
          onPressed: () => tapped++,
        ),
      ]));

      // A single labelled direct FAB — no "+" toggle, no expansion.
      expect(find.byType(AppFAB), findsOneWidget);
      expect(find.text('Receive Stock'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsNothing);
      // Its one-line description only ever shows in the expanded menu.
      expect(find.text('Log a delivery from a supplier'), findsNothing);

      await tester.tap(find.text('Receive Stock'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });

    testWidgets('two actions render an expandable dial', (tester) async {
      var added = 0;
      var received = 0;
      await tester.pumpWidget(_host([
        AppSpeedDialAction(
          icon: Icons.sell,
          label: 'Add Product',
          description: 'Create a product and set what is on your shelf',
          onPressed: () => added++,
        ),
        AppSpeedDialAction(
          icon: Icons.local_shipping,
          label: 'Receive Stock',
          description: 'Log a delivery from a supplier',
          onPressed: () => received++,
        ),
      ]));

      // Collapsed: a single "+" toggle, no labels, no direct AppFAB.
      expect(find.byType(AppFAB), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.text('Add Product'), findsNothing);
      expect(find.text('Receive Stock'), findsNothing);

      // Expand: both labelled options with their one-line descriptions.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('Add Product'), findsOneWidget);
      expect(find.text('Receive Stock'), findsOneWidget);
      expect(
        find.text('Create a product and set what is on your shelf'),
        findsOneWidget,
      );
      expect(find.text('Log a delivery from a supplier'), findsOneWidget);

      // Choosing an option runs its callback and collapses the dial.
      await tester.tap(find.text('Add Product'));
      await tester.pumpAndSettle();
      expect(added, 1);
      expect(received, 0);
      expect(find.text('Add Product'), findsNothing);
      expect(find.text('Receive Stock'), findsNothing);
    });

    testWidgets('tapping the scrim dismisses without choosing', (tester) async {
      var chose = 0;
      await tester.pumpWidget(_host([
        AppSpeedDialAction(
          icon: Icons.sell,
          label: 'Add Product',
          description: 'Create a product',
          onPressed: () => chose++,
        ),
        AppSpeedDialAction(
          icon: Icons.local_shipping,
          label: 'Receive Stock',
          description: 'Log a delivery',
          onPressed: () => chose++,
        ),
      ]));

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('Add Product'), findsOneWidget);

      // Tap the scrim at the top-left, well away from the pills at bottom-right.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(chose, 0);
      expect(find.text('Add Product'), findsNothing);
    });
  });
}
