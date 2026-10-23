// Visual goldens for Product Details (#487 PR 3): the hero, Description,
// Prices & Profit, Stock by Store, Sales Target, Sales, Stock History and
// Manage Product, in one, two and three columns. Screens at 390x2200 (gesture
// nav, bottom 24), 844x390 (status bar 24, 3-button nav on the right 48),
// 800x1500 (two columns) and 1280x1000 (three columns); light + dark. Also an
// archived product and a cashier's view-only look. The clock is pinned (22
// Oct 2026) and the Sales and Stock History rows are seeded on fixed dates, so
// nothing depends on the real date. Regenerate with:
//
//     flutter test --update-goldens test/redesign/product_detail_golden_test.dart

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/product_detail_seed.dart';
import '../helpers/screen_harness.dart';

/// Fixed-date sales and stock movements for Gulder (the sample's own movement
/// carries the real date, so it is voided; the ledger is append-only).
Future<void> _seedSalesAndHistory(
  ScreenTestEnvironment env,
  InventorySample sample,
) async {
  final db = env.db;
  final productId = sample.productIds['Gulder']!;
  await db
      .update(db.stockTransactions)
      .write(StockTransactionsCompanion(voidedAt: Value(DateTime(2026, 1, 1))));
  for (final (daysAgo, qty, cost) in const [
    (0, 4, 1350000),
    (1, 9, 1350000),
    (2, 6, 0),
    (4, 11, 1350000),
    (5, 3, 1350000),
    (9, 7, 1350000),
  ]) {
    final at = DateTime(2026, 10, 22 - daysAgo, 11);
    final orderId = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: env.businessId,
            orderNumber: 'ORD-$orderId',
            totalAmountKobo: qty * 1500000,
            netAmountKobo: qty * 1500000,
            paymentType: 'cash',
            status: 'pending',
            storeId: Value(env.storeId),
            createdAt: Value(at),
          ),
        );
    await db
        .into(db.orderItems)
        .insert(
          OrderItemsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            orderId: orderId,
            productId: Value(productId),
            storeId: env.storeId,
            quantity: qty,
            unitPriceKobo: 1500000,
            totalKobo: qty * 1500000,
            buyingPriceKobo: Value(cost),
          ),
        );
  }
  for (final (type, delta, at, reason) in [
    ('sale', -2, DateTime(2026, 10, 22, 10, 30), 'Sale'),
    ('purchase_received', 30, DateTime(2026, 10, 21, 9, 5), 'Delivery'),
    ('adjustment', -1, DateTime(2026, 10, 20, 18, 40), 'Damaged'),
    ('transfer_out', -10, DateTime(2026, 10, 19, 14, 0), 'Transfer'),
    ('sale', -5, DateTime(2026, 10, 19, 13, 22), 'Sale'),
  ]) {
    final adjId = UuidV7.generate();
    await db
        .into(db.stockAdjustments)
        .insert(
          StockAdjustmentsCompanion.insert(
            id: Value(adjId),
            businessId: env.businessId,
            productId: productId,
            storeId: env.storeId,
            quantityDiff: delta,
            reason: reason,
            performedBy: Value(sample.staffId),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
    await db
        .into(db.stockTransactions)
        .insert(
          StockTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            productId: productId,
            locationId: env.storeId,
            quantityDelta: delta,
            movementType: type,
            adjustmentId: Value(adjId),
            performedBy: Value(sample.staffId),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
  }
}

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
    await _seedSalesAndHistory(env, sample);
  });

  tearDown(() => env.dispose());

  const sizes = <(String, Size, FakeViewPadding)>[
    // The page scrolls, so the tall sizes are tall enough to show every card:
    // 390x2200 is one column, 800x1500 two columns, 1280x1000 three columns,
    // and 844x390 is the phone sideways (its top slice).
    ('390x2200', Size(390, 2200), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1500', Size(800, 1500), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x1000', Size(1280, 1000), FakeViewPadding(top: 24)),
  ];

  const ceoKeys = {
    ...kInventorySampleGrants,
    'products.edit_buying_price',
    'products.delete',
  };

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required FakeViewPadding insets,
    required Brightness brightness,
    Set<String> grants = ceoKeys,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: ProductDetailScreen(
        item: detailItemFor(env, sample),
        onUpdateStock: () {},
        selectedStoreId: env.storeId,
        clock: () => DateTime(2026, 10, 22, 12),
      ),
      followView: true,
      settle: false,
      grantedKeys: grants,
      roleSlug: roleSlug,
      roleRank: roleRank,
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
      matchesGoldenFile('goldens/product_detail_$name.png'),
    );
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    for (final (sizeName, size, insets) in sizes) {
      testWidgets('product detail, $sizeName $themeName', (tester) async {
        await seedDetailSample(env, sample);
        await shoot(
          tester,
          name: '${sizeName}_$themeName',
          size: size,
          insets: insets,
          brightness: brightness,
        );
      });
    }
  }

  testWidgets('product detail, archived product, 390x2200 light', (
    tester,
  ) async {
    await seedDetailSample(env, sample, archived: true);
    await shoot(
      tester,
      name: 'archived_390x2200_light',
      size: const Size(390, 2200),
      insets: const FakeViewPadding(top: 24, bottom: 24),
      brightness: Brightness.light,
    );
  });

  testWidgets('product detail, cashier view-only, 390x2200 light', (
    tester,
  ) async {
    await seedDetailSample(env, sample);
    await shoot(
      tester,
      name: 'cashier_390x2200_light',
      size: const Size(390, 2200),
      insets: const FakeViewPadding(top: 24, bottom: 24),
      brightness: Brightness.light,
      grants: const {'sales.make', 'stock.view'},
      roleSlug: 'cashier',
      roleRank: GateTier.cashier,
    );
  });
}
