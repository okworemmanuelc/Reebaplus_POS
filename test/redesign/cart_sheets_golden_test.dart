// Visual goldens for the Cart's two restyled sheets (#393, PRD #346 Wave 2 A):
// Select Customer (Change) and Saved Carts (Recall), at 390×844 and 844×390
// (with insets), light + dark. Sample data only.
//
//     flutter test --update-goldens test/redesign/cart_sheets_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/pos/widgets/cart/cart_parts.dart';

import '../helpers/screen_harness.dart';
import '../pos/cart_sheet_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late List<String> ids;

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  setUp(() async {
    env = await setupScreenTestEnvironment();
    ids = await seedCartSheetData(env);
  });
  tearDown(() async => env.dispose());

  const cases = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 48)),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  ];

  const sheets = <(Key, String)>[
    (CartKeys.change, 'cart_customer_picker'),
    (CartKeys.recall, 'cart_saved_carts'),
  ];

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (opener, name) in sheets) {
      for (final (sizeName, size, padding) in cases) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pumpCartForSheets(
            tester,
            env: env,
            ids: ids,
            size: size,
            padding: padding,
            brightness: brightness,
          );
          final button = find.byKey(opener);
          // Sideways the Cart's footer scrolls at the end of the lines.
          if (button.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              button,
              200,
              scrollable: find.byType(Scrollable).first,
            );
          }
          await tester.ensureVisible(button);
          await tester.pump();
          await tester.tap(button);
          await settleCartSheets(tester);
          await expectLater(
            find.byType(Navigator).first,
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}
