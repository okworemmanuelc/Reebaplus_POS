// Visual goldens for Home's Record Payment chooser (#362 PR 4, PRD #270
// "Tile destinations"): "Record Payment" with "Customer paid us" and "We paid
// a supplier", shown when the viewer has both payment sides.
//
// 390x844 (gesture nav, bottom 24) and 844x390 (status bar 24, 3-button nav
// on the right 48), light + dark. The sheet opens on a tab-like nested
// navigator, as in the app. Regenerate with:
//
//     flutter test --update-goldens test/redesign/record_payment_chooser_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/quick_actions.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/record_payment_chooser.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (size, insets) in const [
      (Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      (Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      final sizeName = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('record payment chooser, $sizeName $themeName', (
        tester,
      ) async {
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const _Host(),
          bottomNavHeight: 0,
          followView: true,
          grantedKeys: const {'customers.wallet.update', 'suppliers.manage'},
          roleRank: GateTier.ceo,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          settle: false,
        );
        await tester.pump();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(RecordPaymentChooserKeys.sheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/record_payment_chooser_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}

/// A tab-like host: Scaffold → nested Navigator → an "open" button.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: TextButton(
                onPressed: () => showRecordPaymentChooser(
                  context,
                  sides: PaymentSide.values,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
