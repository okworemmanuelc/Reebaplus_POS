// Visual goldens for Receive Stock (#394, PRD #346 Wave 2 A):
//
// `receive_stock_{390x844,844x390_insets,800x1280,1280x800}_{light,dark}`:
// a CEO on "Abuja HQ" with two products on the receipt (badges, the
// "Review Items (2)" bar the fly-to-cart lands on), the coach hint, the
// category chips, the New Product cell and an out-of-stock tile that is still
// live ("No stock", not dimmed). The long product name ellipsizes. At 600dp+
// the frame's rail is a blank strip on the left (as the harness draws it);
// 844x390 carries a sideways phone's insets (top 24, right 48). Regenerate
// with:
//
//     flutter test --update-goldens test/redesign/receive_stock_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';

import '../helpers/screen_harness.dart';
import '../receiving/receive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReceiveFixture fx;

  setUp(() async => fx = await ReceiveFixture.create());
  tearDown(() => fx.env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  const cases = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.zero),
    ('844x390_insets', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), EdgeInsets.zero),
    ('1280x800', Size(1280, 800), EdgeInsets.zero),
  ];

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (name, size, padding) in cases) {
      testWidgets('receive stock $name $themeName', (tester) async {
        await pumpScreen(
          tester,
          env: fx.env,
          size: size,
          padding: padding,
          screen: const ReceiveStockScreen(),
          // A pushed screen: no bottom bar; the rail stays at 600dp+.
          bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
          grantedKeys: const {
            'stock.add',
            'products.add',
            'products.edit_price',
          },
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          settle: false,
        );
        await settle(tester);
        // Eva Water ×3 and the long Guinness ×1: the first row's tiles.
        for (final (i, taps) in [(3, 3), (2, 1)]) {
          final tile = find.byKey(receiveProductTileKey(fx.productIds[i]));
          for (var t = 0; t < taps; t++) {
            await tester.tap(tile);
            await tester.pump();
          }
        }
        // Let the fly-to animations land.
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(ReceiveStockScreen),
          matchesGoldenFile('goldens/receive_stock_${name}_$themeName.png'),
        );
        await disposeScreen(tester);
      });
    }
  }
}
