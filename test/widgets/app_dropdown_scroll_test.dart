import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

/// `AppDropdown`'s open menu must not freeze the page under it.
///
/// ### Why this exists (found on #259's emulator check)
///
/// The menu's tap-outside-to-dismiss barrier was a
/// `Container(color: Colors.transparent)` sized to the whole screen. A
/// `Container` with a colour builds a `ColoredBox`, and **a `ColoredBox`
/// hit-tests itself even when the colour is fully transparent** — so the
/// barrier consumed the drag and `HitTestBehavior.translucent` never got the
/// chance to pass it through. Every page behind an open dropdown was frozen.
///
/// It went unnoticed for as long as it did because the screens holding these
/// 58 dropdowns did not scroll. POS becoming one scrolling surface (#259) is
/// what made it visible.
///
/// Two behaviours are pinned here, and they are in tension — which is the
/// reason to test both in one file:
///
///   1. The page still scrolls while the menu is open.
///   2. The barrier still dismisses the menu on a tap outside it.
///
/// Fixing (1) by deleting the barrier would silently cost (2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A dropdown near the top of a long scrollable page.
  Widget harness({ScrollController? controller}) {
    String? value = 'a';
    return MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => CustomScrollView(
            controller: controller,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: AppDropdown<String>(
                    value: value,
                    items: const [
                      DropdownMenuItem(value: 'a', child: Text('Alpha')),
                      DropdownMenuItem(value: 'b', child: Text('Beta')),
                    ],
                    onChanged: (v) => setState(() => value = v),
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (_, i) => SizedBox(
                  height: 60,
                  child: Text('row $i'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('the page still scrolls while the menu is open', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller: controller));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget, reason: 'the menu must be open');

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: 'An open dropdown must not freeze the page underneath it',
    );
  });

  testWidgets('scrolling dismisses the menu', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller: controller));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
    await tester.pumpAndSettle();

    // A field inside a lazy sliver unmounts once it scrolls past the cache
    // extent, and `showWhenUnlinked: false` would then hide the menu while
    // leaving the barrier live — an invisible surface eating every tap.
    // Closing on scroll keeps that state unreachable.
    expect(
      find.text('Beta'),
      findsNothing,
      reason: 'A scroll must dismiss the menu, not orphan it',
    );
  });

  testWidgets('a tap outside still dismisses the menu', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);

    // Well below the menu but inside the 800x600 test surface, so the tap
    // lands on the barrier. This is what the barrier is for; making the page
    // scrollable again must not cost it.
    await tester.tapAt(const Offset(400, 550));
    await tester.pumpAndSettle();

    expect(
      find.text('Beta'),
      findsNothing,
      reason: 'Tap-outside-to-dismiss must survive the hit-test fix',
    );
  });

  testWidgets('picking an item still reports the new value', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(
      find.text('Beta'),
      findsOneWidget,
      reason: 'The field must show the picked value',
    );
    expect(find.text('Alpha'), findsNothing);
  });
}
