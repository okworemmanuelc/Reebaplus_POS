// Visual goldens for the "Get started" card restyle (D2 PR 2, #463): the card
// alone at 390 and 800 wide, light and dark, in three states (nothing done,
// store + product done, store done with the rest locked-free). PNGs live in
// test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/get_started_card_golden_test.dart
//
// Also checks no overflow at 360dp @1.3 and that every tappable step row and
// the dismiss button are at least 48dp tall.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/get_started_card.dart';

GetStartedChecklistState _state({
  bool store = false,
  bool product = false,
  bool sale = false,
  bool team = false,
}) => GetStartedChecklistState(
  visible: true,
  steps: [
    GetStartedStep(id: GetStartedStepId.createStore, done: store),
    GetStartedStep(
      id: GetStartedStepId.addProduct,
      done: product,
      locked: !store,
    ),
    GetStartedStep(
      id: GetStartedStepId.makeSale,
      done: sale,
      optional: true,
      locked: !store,
    ),
    GetStartedStep(
      id: GetStartedStepId.inviteTeam,
      done: team,
      optional: true,
      locked: !store,
    ),
  ],
);

void main() {
  setUp(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDown(() => WidgetsApp.debugAllowBannerOverride = true);

  final states = <String, GetStartedChecklistState>{
    'none_done': _state(),
    'some_done': _state(store: true, product: true),
  };
  const widths = <String, double>{'390': 390, '800': 800};

  Future<void> pump(
    WidgetTester tester, {
    required GetStartedChecklistState state,
    required double width,
    required Brightness brightness,
    double scale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [getStartedChecklistProvider.overrideWithValue(state)],
        child: MaterialApp(
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RepaintBoundary(
                      key: const ValueKey('card'),
                      child: ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: GetStartedCard(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Unmounts and lets any pending timer (spotlight registration) drain.
  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  for (final s in states.entries) {
    for (final w in widths.entries) {
      for (final brightness in Brightness.values) {
        final themeKey = brightness == Brightness.light ? 'light' : 'dark';
        testWidgets('card ${s.key} ${w.key} $themeKey', (tester) async {
          await pump(
            tester,
            state: s.value,
            width: w.value,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(const ValueKey('card')),
            matchesGoldenFile(
              'goldens/get_started_checklist_${s.key}_${w.key}_$themeKey.png',
            ),
          );
          await drain(tester);
        });
      }
    }
  }

  for (final s in states.entries) {
    testWidgets('card ${s.key}: no overflow at 360 @1.3', (tester) async {
      await pump(
        tester,
        state: s.value,
        width: 360,
        brightness: Brightness.light,
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tappable rows and Dismiss are at least 48dp', (tester) async {
    await pump(
      tester,
      state: _state(store: true, product: true),
      width: 390,
      brightness: Brightness.light,
    );
    final dismiss = tester.getSize(find.byTooltip('Dismiss'));
    expect(dismiss.height, greaterThanOrEqualTo(48));
    expect(dismiss.width, greaterThanOrEqualTo(48));
    // The two unticked, unlocked rows deep-link; each is an InkWell.
    for (final row in find.byType(InkWell).evaluate()) {
      final size = tester.getSize(find.byWidget(row.widget));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });
}
