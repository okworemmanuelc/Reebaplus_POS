import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    SpotlightTargetRegistry.clear();
  });

  group('SpotlightOverlay target tracking', () {
    testWidgets('hole follows a target that animates into place', (
      tester,
    ) async {
      // The drawer slides in over ~250 ms. Resolving the rect once, on the
      // frame the target mounts, freezes the hole off-screen and leaves the
      // owner under a fully dark sheet with nothing to tap.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                _SlidingTarget(),
                SpotlightOverlay(
                  targetId: SpotlightTargetId.drawerStoresItem,
                  caption: 'Tap Stores',
                  blocking: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hole = tester
          .renderObject<RenderSpotlightOverlay>(
            find.byWidgetPredicate(
              (w) => w is LeafRenderObjectWidget && w.runtimeType.toString() ==
                  '_SpotlightOverlayBackground',
            ),
          )
          .paddedHoleRect;

      expect(hole, isNotNull);
      // Target settles at left: 0, top: 100, 60x40, with 6px hole padding.
      expect(hole!.left, -6);
      expect(hole.top, 94);
    });
  });

  group('SpotlightOverlay', () {
    testWidgets('renders cutout hole over target rect with caption', (tester) async {
      const targetRect = Rect.fromLTWH(50, 50, 100, 40);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                SizedBox.expand(),
                SpotlightOverlay(
                  targetRect: targetRect,
                  caption: 'Tap here to continue',
                  blocking: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tap here to continue'), findsOneWidget);
    });

    testWidgets('blocking mode: tap inside hole fires underlying button', (tester) async {
      bool buttonTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 100,
                  left: 100,
                  child: ElevatedButton(
                    onPressed: () => buttonTapped = true,
                    child: const Text('Target Button'),
                  ),
                ),
                const SpotlightOverlay(
                  targetRect: Rect.fromLTWH(100, 100, 150, 48),
                  caption: 'Tap the button',
                  blocking: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap inside the hole on the button
      await tester.tap(find.text('Target Button'));
      await tester.pumpAndSettle();

      expect(buttonTapped, isTrue);
    });

    testWidgets('blocking mode: tap outside hole is swallowed', (tester) async {
      bool outsideButtonTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 300,
                  left: 100,
                  child: ElevatedButton(
                    onPressed: () => outsideButtonTapped = true,
                    child: const Text('Outside Button'),
                  ),
                ),
                const SpotlightOverlay(
                  targetRect: Rect.fromLTWH(50, 50, 100, 40),
                  caption: 'Focus on top',
                  blocking: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap outside the hole on the outside button
      await tester.tap(find.text('Outside Button'));
      await tester.pumpAndSettle();

      // In blocking mode, outside taps are swallowed!
      expect(outsideButtonTapped, isFalse);
    });

    testWidgets('blocking mode: drags pass through to underlying scrollable', (tester) async {
      final scrollController = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ListView.builder(
                  controller: scrollController,
                  itemCount: 50,
                  itemBuilder: (_, i) => SizedBox(
                    height: 50,
                    child: Text('Item $i'),
                  ),
                ),
                const SpotlightOverlay(
                  targetRect: Rect.fromLTWH(20, 20, 100, 40),
                  caption: 'Scroll the list',
                  blocking: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(scrollController.offset, 0.0);

      // Drag vertically outside the hole
      await tester.dragFrom(const Offset(200, 300), const Offset(0, -200));
      await tester.pumpAndSettle();

      // Scroll position must have moved!
      expect(scrollController.offset, greaterThan(0.0));
    });

    testWidgets('non-blocking mode: taps outside hole pass through to underlying buttons',
        (tester) async {
      bool outsideButtonTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 300,
                  left: 100,
                  child: ElevatedButton(
                    onPressed: () => outsideButtonTapped = true,
                    child: const Text('Outside Button'),
                  ),
                ),
                const SpotlightOverlay(
                  targetRect: Rect.fromLTWH(50, 50, 100, 40),
                  caption: 'Non-blocking pointer',
                  blocking: false,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap outside button in non-blocking mode
      await tester.tap(find.text('Outside Button'));
      await tester.pumpAndSettle();

      // In non-blocking mode, taps pass through!
      expect(outsideButtonTapped, isTrue);
    });

    testWidgets('missing target triggers onMissingTarget without crash', (tester) async {
      bool missingTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpotlightOverlay(
              targetId: SpotlightTargetId.menuButton, // not mounted anywhere in tree
              caption: 'Cannot find this',
              targetLookupTimeout: const Duration(milliseconds: 100),
              onMissingTarget: () {
                missingTriggered = true;
              },
            ),
          ),
        ),
      );

      // Advance past timeout
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      expect(missingTriggered, isTrue);
    });

    testWidgets('targetId resolves rect when mounted with SpotlightTarget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 80,
                  left: 40,
                  child: SpotlightTarget(
                    id: SpotlightTargetId.menuButton,
                    child: SizedBox(width: 48, height: 48),
                  ),
                ),
                SpotlightOverlay(
                  targetId: SpotlightTargetId.menuButton,
                  caption: 'Tap the menu',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tap the menu'), findsOneWidget);
      final targetRect = SpotlightTargetRegistry.getTargetRect(SpotlightTargetId.menuButton);
      expect(targetRect, isNotNull);
      expect(targetRect!.top, 80.0);
      expect(targetRect.left, 40.0);
      expect(targetRect.width, 48.0);
      expect(targetRect.height, 48.0);
    });
  });
}


/// A target that slides in from off-screen, mimicking the navigation drawer.
class _SlidingTarget extends StatefulWidget {
  const _SlidingTarget();

  @override
  State<_SlidingTarget> createState() => _SlidingTargetState();
}

class _SlidingTargetState extends State<_SlidingTarget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Positioned(
        left: -300 + 300 * _controller.value,
        top: 100,
        child: const SpotlightTarget(
          id: SpotlightTargetId.drawerStoresItem,
          child: SizedBox(width: 60, height: 40),
        ),
      ),
    );
  }
}
