import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SpotlightTargetRegistry.clear);

  group('SpotlightTargetRegistry revision bumps', () {
    testWidgets(
      'a target mounting mid-build does not mark an unrelated listener dirty',
      (tester) async {
        // Reproduces the production crash: a ListenableBuilder watching the
        // registry sits in a sibling subtree, and a SpotlightTarget is then
        // mounted elsewhere in the same frame. Registering synchronously would
        // call markNeedsBuild() on a listener that is not an ancestor of the
        // widget being built => "setState() or markNeedsBuild() called during
        // build".
        final showTarget = ValueNotifier<bool>(false);
        addTearDown(showTarget.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: showTarget,
                    builder: (context, show, _) => show
                        ? const SpotlightTarget(
                            id: SpotlightTargetId.menuButton,
                            child: SizedBox(width: 40, height: 40),
                          )
                        : const SizedBox.shrink(),
                  ),
                  ListenableBuilder(
                    listenable: SpotlightTargetRegistry.registryRevision,
                    builder: (context, _) => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        );

        showTarget.value = true;
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
          SpotlightTargetRegistry.getKey(SpotlightTargetId.menuButton),
          isNotNull,
        );
      },
    );

    testWidgets('a target unmounting mid-build does not throw', (tester) async {
      final showTarget = ValueNotifier<bool>(true);
      addTearDown(showTarget.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: showTarget,
                  builder: (context, show, _) => show
                      ? const SpotlightTarget(
                          id: SpotlightTargetId.menuButton,
                          child: SizedBox(width: 40, height: 40),
                        )
                      : const SizedBox.shrink(),
                ),
                ListenableBuilder(
                  listenable: SpotlightTargetRegistry.registryRevision,
                  builder: (context, _) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      );

      showTarget.value = false;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        SpotlightTargetRegistry.getTargetRect(SpotlightTargetId.menuButton),
        isNull,
      );
    });
  });

  group('SpotlightTargetRegistry movement tracking', () {
    testWidgets(
      'a listener re-derives visibility once a target finishes animating in',
      (tester) async {
        // The drawer slides in over ~250 ms. Its Stores entry is off-screen on
        // the frame it registers, so a one-shot read leaves the rail saying
        // "Scroll down to find Stores" while Stores sits in plain view.
        final visibilitySamples = <bool>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const _SlidingTarget(),
                  // Stands in for the tour view: rebuilds off registryRevision
                  // and re-derives the sub-step from the target's rect.
                  ListenableBuilder(
                    listenable: SpotlightTargetRegistry.registryRevision,
                    builder: (context, _) {
                      visibilitySamples.add(
                        SpotlightTargetRegistry.isVisibleOnScreen(
                          SpotlightTargetId.drawerStoresItem,
                          screenSize: const Size(800, 600),
                        ),
                      );
                      return const SpotlightOverlay(
                        targetId: SpotlightTargetId.drawerStoresItem,
                        caption: 'Tap Stores',
                        blocking: true,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(visibilitySamples.first, isFalse, reason: 'starts off-screen');
        expect(visibilitySamples.last, isTrue, reason: 'settles on-screen');
      },
    );

    testWidgets('tracking stops when the last overlay is disposed', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                SpotlightTarget(
                  id: SpotlightTargetId.menuButton,
                  child: SizedBox(width: 40, height: 40),
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

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(SpotlightTargetRegistry.debugIsTracking, isFalse);
    });
  });

  group('SpotlightTargetRegistry target selection', () {
    testWidgets('ignores an offstage duplicate and resolves the visible one', (
      tester,
    ) async {
      // MainLayout keeps every visited tab mounted under an Offstage, and each
      // tab carries its own MenuButton. The offstage copy is still laid out, so
      // it must be rejected on paint-visibility, not on size.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Offstage(
                  child: SpotlightTarget(
                    id: SpotlightTargetId.menuButton,
                    child: SizedBox(width: 40, height: 40),
                  ),
                ),
                Positioned(
                  top: 120,
                  left: 30,
                  child: Offstage(
                    offstage: false,
                    child: SpotlightTarget(
                      id: SpotlightTargetId.menuButton,
                      child: SizedBox(width: 40, height: 40),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rect = SpotlightTargetRegistry.getTargetRect(
        SpotlightTargetId.menuButton,
      );

      expect(rect, isNotNull);
      expect(rect!.left, 30);
      expect(rect.top, 120);
    });

    testWidgets('returns null when every registration is offstage', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Offstage(
              child: SpotlightTarget(
                id: SpotlightTargetId.createStoreFab,
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        SpotlightTargetRegistry.getTargetRect(SpotlightTargetId.createStoreFab),
        isNull,
      );
    });
  });
}

/// Slides a target in from off-screen, the way the navigation drawer does.
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
