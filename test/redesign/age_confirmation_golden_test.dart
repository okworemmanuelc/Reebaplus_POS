// Visual goldens for the 18+ confirmation pop-up (#479) at 390x844 and
// 844x390 (24dp status bar + 48dp side inset), plus a no-overflow check at
// 360x640 with text at 1.15. No Claude Design file exists for it; it follows
// ui-context tokens and the Browse parts. Regenerate with:
//
//     flutter test --update-goldens test/redesign/age_confirmation_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/browse/widgets/age_confirmation_dialog.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  EdgeInsets padding = EdgeInsets.zero,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (padding != EdgeInsets.zero) {
    tester.view.padding = FakeViewPadding(
        top: padding.top, right: padding.right, left: padding.left);
    tester.view.viewPadding = FakeViewPadding(
        top: padding.top, right: padding.right, left: padding.left);
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => const AgeConfirmationDialog(),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  const sizes = <String, (Size, EdgeInsets, Brightness)>{
    '390x844': (Size(390, 844), EdgeInsets.zero, Brightness.light),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48), Brightness.dark),
  };
  for (final size in sizes.entries) {
    final name = 'age_confirmation_${size.key}_${size.value.$3.name}';
    testWidgets(name, (tester) async {
      await _pump(tester,
          size: size.value.$1, padding: size.value.$2, brightness: size.value.$3);
      expect(tester.takeException(), isNull);
      expect(find.text(AgeConfirmationDialog.confirmLabel), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    });
  }

  for (final size in const [Size(360, 640), Size(844, 390)]) {
    testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}, text 1.15',
        (tester) async {
      await _pump(tester, size: size, textScale: 1.15);
      expect(tester.takeException(), isNull);
      // Both answers stay reachable (the pop-up scrolls).
      await tester.ensureVisible(find.text(AgeConfirmationDialog.declineLabel));
      await tester.pumpAndSettle();
      expect(find.text(AgeConfirmationDialog.declineLabel).hitTestable(), findsOneWidget);
    });
  }
}
