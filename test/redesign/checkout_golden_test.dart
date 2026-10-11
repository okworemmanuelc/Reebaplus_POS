// Visual goldens for the Checkout restyle (#393, PRD #346 Wave 2 A).
//
// A crate business, a registered customer with ₦5,000 credit, the Cart's
// sample lines with a discount, crates and a part deposit entered, at the
// four sizes in light + dark (the top of the form); `checkout_payment_*` the
// payment half at 390×844; `checkout_deposit_sheet_*` the per-brand deposit
// sheet.
//
// Sample data only. The PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/checkout_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';

import '../helpers/screen_harness.dart';
import '../pos/checkout_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    // Checkout is pumped without the frame, so hide the debug banner here.
    WidgetsApp.debugAllowBannerOverride = false;
    env = await setupScreenTestEnvironment(businessType: 'Bar');
  });
  tearDown(() async {
    WidgetsApp.debugAllowBannerOverride = true;
    await env.dispose();
  });

  const cases = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 48)),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), EdgeInsets.only(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), EdgeInsets.only(top: 24)),
  ];

  /// Enters a ₦1,500 deposit for Nigerian Breweries and ₦20,000 paid.
  Future<void> fillForm(WidgetTester tester) async {
    final row = find.byKey(CheckoutKeys.depositRow('mfr-nb'));
    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await settleCheckout(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(CheckoutKeys.depositSheet),
        matching: find.byType(TextField),
      ),
      '1500',
    );
    await tester.tap(find.text('Save'));
    await settleCheckout(tester);
    final amount = find.descendant(
      of: find.byKey(CheckoutKeys.amountPaid),
      matching: find.byType(TextField),
    );
    await tester.enterText(amount, '20000');
    FocusManager.instance.primaryFocus?.unfocus();
    await settleCheckout(tester);
    // Back to the top for the picture.
    await tester.drag(find.byKey(CheckoutKeys.form), const Offset(0, 4000));
    await settleCheckout(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (sizeName, size, padding) in cases) {
      testWidgets('checkout $sizeName $themeName', (tester) async {
        await pumpCheckout(
          tester,
          env: env,
          size: size,
          padding: padding,
          brightness: brightness,
          customer: checkoutCustomer,
          creditKobo: 500000,
          crates: true,
        );
        await fillForm(tester);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile('goldens/checkout_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });
    }

    testWidgets('checkout payment 390x844 $themeName', (tester) async {
      await pumpCheckout(
        tester,
        env: env,
        brightness: brightness,
        customer: checkoutCustomer,
        creditKobo: 500000,
        crates: true,
      );
      await fillForm(tester);
      // The payment half: scroll to the end.
      await tester.drag(find.byKey(CheckoutKeys.form), const Offset(0, -4000));
      await settleCheckout(tester);
      await expectLater(
        find.byType(Navigator).first,
        matchesGoldenFile('goldens/checkout_payment_390x844_$themeName.png'),
      );
      await disposeScreen(tester);
    });

    for (final (sizeName, size, padding) in cases.take(2)) {
      testWidgets('checkout deposit sheet $sizeName $themeName', (
        tester,
      ) async {
        await pumpCheckout(
          tester,
          env: env,
          size: size,
          padding: padding,
          brightness: brightness,
          customer: checkoutCustomer,
          creditKobo: 500000,
          crates: true,
        );
        final row = find.byKey(CheckoutKeys.depositRow('mfr-nb'));
        await tester.ensureVisible(row);
        await tester.pump();
        await tester.tap(row);
        await settleCheckout(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await settleCheckout(tester);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/checkout_deposit_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
