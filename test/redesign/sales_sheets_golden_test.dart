// Visual goldens for the restyled sales sheets (#393, PRD #346 Wave 2 A):
// Edit Item, Add to Cart, Quick Sale, the three scan sheets and the camera
// sheet, at 390×844 and 844×390 (with insets), light + dark. The Cart's two
// pickers are in `cart_sheets_golden_test.dart`.
//
// Sample data only. The PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/sales_sheets_golden_test.dart

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';

import '../helpers/fake_barcode_scanner.dart';
import '../helpers/screen_harness.dart';
import '../pos/sales_sheet_hosts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 2);
    final db = env.db;
    const names = ['Star Lager', 'Hero Lager'];
    for (var i = 0; i < 2; i++) {
      await (db.update(
        db.products,
      )..where((t) => t.id.equals(env.products[i].id))).write(
        ProductsCompanion(
          name: Value(names[i]),
          barcode: Value(i == 0 ? '6151100099887' : null),
        ),
      );
    }
    env = ScreenTestEnvironment(
      db: db,
      businessId: env.businessId,
      storeId: env.storeId,
      store: env.store,
      categoryId: env.categoryId,
      products: await db.select(db.products).get(),
      manufacturers: env.manufacturers,
    );
  });
  tearDown(() async => env.dispose());

  const cases = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 48)),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  ];

  const sheets = <(SalesSheet, String)>[
    (SalesSheet.editItem, 'edit_item'),
    (SalesSheet.addToCart, 'add_to_cart'),
    (SalesSheet.quickSale, 'quick_sale'),
    (SalesSheet.quickSaleApproval, 'quick_sale_approval'),
    (SalesSheet.scanWhichOne, 'scan_which_one'),
    (SalesSheet.scanUnknownChoice, 'scan_unknown_choice'),
    (SalesSheet.scanLinkProduct, 'scan_link_product'),
    (SalesSheet.cameraPermission, 'camera_permission'),
  ];

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (sheet, name) in sheets) {
      for (final (sizeName, size, padding) in cases) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pumpSheet(
            tester,
            env: env,
            sheet: sheet,
            size: size,
            padding: padding,
            brightness: brightness,
          );
          await unfocus(tester);
          await expectLater(
            find.byType(Navigator).first,
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (sizeName, size, padding) in cases) {
      testWidgets('barcode_scan $sizeName $themeName', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: padding,
          bottomNavHeight: 0,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          screen: BarcodeScanPage(
            createCamera: () => FakeScanCamera(),
            onCode: (_, _) async {},
          ),
          settle: false,
        );
        await settleSheet(tester);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile('goldens/barcode_scan_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });
    }
  }
}
