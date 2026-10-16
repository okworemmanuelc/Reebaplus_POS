// Visual goldens for Product Detail (#392 PR 3, Wave 2 A): the solid top bar,
// the identity card, Pricing, Stock & Info, Sales Summary / Target and Last
// Delivery. Screens at 390x844 (gesture nav, bottom 24), 844x390 (status bar
// 24, 3-button nav on the right 48), 800x1280 and 1280x800; light + dark.
// Sample data has no orders or shipments, so nothing depends on the clock.
// Regenerate with:
//
//     flutter test --update-goldens test/redesign/product_detail_golden_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    WidgetsApp.debugAllowBannerOverride = false;
    docs = Directory.systemTemp.createTempSync('product_detail_golden');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    WidgetsApp.debugAllowBannerOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  const sizes = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (sizeName, size, insets) in sizes) {
      testWidgets('product detail, $sizeName $themeName', (tester) async {
        tester.view.padding = insets;
        tester.view.viewPadding = insets;
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: ProductDetailScreen(
            item: InventoryItem(
              id: sample.productIds['Gulder']!,
              productName: 'Gulder',
              subtitle: '60cl',
              icon: Icons.local_drink,
              color: Colors.blue,
              storeStock: {env.storeId: 4},
              lowStockThreshold: 5,
              unit: 'Bottle',
            ),
            onUpdateStock: () {},
            selectedStoreId: env.storeId,
          ),
          followView: true,
          settle: false,
          grantedKeys: const {
            ...kInventorySampleGrants,
            'products.edit_buying_price',
            'products.delete',
          },
          roleRank: GateTier.ceo,
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
        );
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/product_detail_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
