// money_input_401_test.dart
//
// Pins the two money-entry fixes in #401:
//   1. Checkout's per-brand deposit sheet keeps the kobo ("Use full" saves the
//      exact full deposit; reopening pre-fills the saved kobo) and refuses an
//      amount above the brand's full deposit. 0 / blank is still "no deposit".
//   2. Edit Item reads a custom price and a ₦ discount written with a thousands
//      comma ("1,500", "1,500.50") as well as without ("1500").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'checkout_fixture.dart';
import 'sales_sheet_hosts.dart';

/// One brand whose full deposit has kobo: 1.5 crates × ₦1,000.33 = ₦1,500.495,
/// rounded to 150,050 kobo (₦1,500.50).
const _mfr = 'mfr-nb';
const _fullKobo = 150050;
final _koboCrateLines = <Map<String, dynamic>>[
  {
    'manufacturerId': _mfr,
    'name': 'Nigerian Breweries',
    'crates': 1.5,
    'rateKobo': 100033,
  },
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  group('Checkout deposit sheet (#401)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(businessType: 'Bar');
    });
    tearDown(() async => env.dispose());

    Finder row() => find.byKey(CheckoutKeys.depositRow(_mfr));
    Finder rowText(String tag) =>
        find.descendant(of: row(), matching: find.textContaining('· $tag'));
    Finder field() => find.descendant(
      of: find.byKey(CheckoutKeys.depositSheet),
      matching: find.byType(TextField),
    );
    Finder save() => find.descendant(
      of: find.byKey(CheckoutKeys.depositSheet),
      matching: find.widgetWithText(AppButton, 'Save'),
    );

    Future<void> openSheet(WidgetTester tester) async {
      await tester.ensureVisible(row());
      await tester.pump();
      await tester.tap(row());
      await settleCheckout(tester);
      expect(find.byKey(CheckoutKeys.depositSheet), findsOneWidget);
    }

    Future<void> pump(WidgetTester tester) => pumpCheckout(
      tester,
      env: env,
      size: const Size(800, 1280),
      customer: checkoutCustomer,
      crateLines: _koboCrateLines,
    );

    testWidgets('"Use full" on a kobo deposit saves exactly the full kobo', (
      tester,
    ) async {
      await pump(tester);
      expect(rowText('No deposit'), findsOneWidget);
      await openSheet(tester);
      await tester.tap(find.textContaining('Use full'));
      await tester.pump();
      expect(tester.widget<TextField>(field()).controller!.text, '1,500.50');
      await tester.tap(save());
      await settleCheckout(tester);
      // isFull is `paidKobo == fullKobo`: "Full" only when no kobo was dropped.
      expect(rowText('Full'), findsOneWidget);
      expect(rowText('Part'), findsNothing);
      await finish(tester);
    });

    testWidgets('reopening the sheet pre-fills a saved kobo amount exactly', (
      tester,
    ) async {
      await pump(tester);
      await openSheet(tester);
      await tester.enterText(field(), '1200.25');
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('Part'), findsOneWidget);
      await openSheet(tester);
      expect(tester.widget<TextField>(field()).controller!.text, '1,200.25');
      // Saving the pre-filled value unchanged keeps the kobo: tapping "Use
      // full" afterwards and saving still lands on exactly the full deposit.
      await tester.tap(find.textContaining('Use full'));
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('Full'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an amount above the full deposit cannot be saved', (
      tester,
    ) async {
      await pump(tester);
      await openSheet(tester);
      await tester.enterText(field(), '1500.51');
      await tester.pump();
      expect(
        find.text(
          "Can't be more than the full deposit "
          '${activeCurrencySymbol}1,500.50',
        ),
        findsOneWidget,
      );
      expect(tester.widget<AppButton>(save()).onPressed, isNull);
      await tester.tap(save(), warnIfMissed: false);
      await settleCheckout(tester);
      // Still open, nothing saved.
      expect(find.byKey(CheckoutKeys.depositSheet), findsOneWidget);
      // Bringing it back to the full deposit clears the message and saves.
      await tester.enterText(field(), '1500.50');
      await tester.pump();
      expect(find.textContaining("Can't be more"), findsNothing);
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('Full'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('0 or a cleared field still means "no deposit"', (
      tester,
    ) async {
      await pump(tester);
      await openSheet(tester);
      await tester.enterText(field(), '500');
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('Part'), findsOneWidget);

      await openSheet(tester);
      await tester.enterText(field(), '0');
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('No deposit'), findsOneWidget);

      await openSheet(tester);
      expect(tester.widget<TextField>(field()).controller!.text, '');
      await tester.enterText(field(), '500');
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      await openSheet(tester);
      await tester.enterText(field(), '');
      await tester.pump();
      await tester.tap(save());
      await settleCheckout(tester);
      expect(rowText('No deposit'), findsOneWidget);
      await finish(tester);
    });
  });

  group('Edit Item money fields (#401)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 2);
    });
    tearDown(() async => env.dispose());

    Finder fieldWithHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );

    // The money fields' formatter strips commas from typed input, so a comma
    // can only reach the parser when the text is set another way. Write the
    // controller directly to pin the parser itself.
    Future<void> setText(WidgetTester tester, Finder f, String text) async {
      tester.widget<TextField>(f).controller!.text = text;
      await tester.pump();
    }

    for (final (typed, shownKobo) in [
      ('1,500', 150000),
      ('1500', 150000),
      ('1,500.50', 150050),
    ]) {
      testWidgets('custom price "$typed" applies', (tester) async {
        // 90% role cap → price floor ₦960, so ₦1,500 is a legal custom price.
        await pumpSheet(
          tester,
          env: env,
          sheet: SalesSheet.editItem,
          maxDiscountPercent: 90,
        );
        await setText(tester, fieldWithHint('Use designated price'), typed);
        expect(
          find.text(
            'Selling at ${formatCurrency(shownKobo / 100.0)} per unit '
            '(was ${formatCurrency(9600)}).',
          ),
          findsOneWidget,
        );
        await finish(tester);
      });

      testWidgets('₦ discount "$typed" applies', (tester) async {
        await pumpSheet(tester, env: env, sheet: SalesSheet.editItem);
        await tester.tap(find.byKey(EditItemKeys.kind('naira')));
        await tester.pump();
        await setText(tester, fieldWithHint('${activeCurrencySymbol}0'), typed);
        // Line: 2 × ₦9,600 = ₦19,200; 20% cap = ₦3,840, so ₦1,500 stands.
        expect(
          find.text(
            'Saving ${formatCurrency(shownKobo / 100.0)} — '
            'new line total: ${formatCurrency((1920000 - shownKobo) / 100.0)}',
          ),
          findsOneWidget,
        );
        await finish(tester);
      });
    }
  });
}
