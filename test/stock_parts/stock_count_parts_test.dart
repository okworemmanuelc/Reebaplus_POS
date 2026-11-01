// Stock Count in parts (#630): a product with its parts switch on can be
// counted at a quarter; a switched-off product only takes whole numbers; an
// off-quarter figure is refused before the review sheet opens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

const _grants = {...kInventorySampleGrants};
const _gesture = FakeViewPadding(top: 24, bottom: 24);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
    await env.db.customStatement(
      "INSERT INTO users (id, business_id, name, pin) VALUES "
      "('test-user-id', '${env.businessId}', 'Test User', '123456')",
    );
  });

  tearDown(() => env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.padding = _gesture;
    tester.view.viewPadding = _gesture;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: StockCountScreen(storeId: env.storeId),
      followView: true,
      settle: false,
      grantedKeys: _grants,
      overrides: [
        todaysBusinessDateProvider.overrideWith((ref) async => '2026-10-01'),
      ],
      roleSlug: 'ceo',
      roleRank: GateTier.ceo,
    );
    await settle(tester);
  }

  Future<void> setParts(bool on) => env.db.customStatement(
    'UPDATE products SET allow_fractional_sales = ${on ? 1 : 0}',
  );

  String firstSystem(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  testWidgets('switch on: counting a quarter above system saves the part', (
    tester,
  ) async {
    await tester.runAsync(() => setParts(true));
    Future<double?> totalStock() => tester.runAsync(
      () async =>
          (await env.db
                  .customSelect('SELECT SUM(quantity) AS q FROM inventory')
                  .getSingle())
              .read<double>('q'),
    );
    final before = await totalStock();
    await pump(tester);
    final system = double.parse(firstSystem(tester));
    await tester.enterText(find.byType(TextField).first, '${system + 0.25}');
    await tester.pump();
    expect(find.text('+0.25'), findsOneWidget);

    await tester.tap(find.text('Save Count'));
    await tester.pumpAndSettle();
    expect(find.text('Review Count'), findsOneWidget);
    await tester.tap(find.text('Confirm & Save Count'));
    await settle(tester);

    final counts = await tester.runAsync(
      () => env.db.stockCountsDao.watchAllForBusiness().first,
    );
    expect(counts!.single.surplusUnits, 0.25);
    expect(await totalStock(), before! + 0.25);
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  testWidgets('switch on: an off-quarter figure is refused up front', (
    tester,
  ) async {
    await tester.runAsync(() => setParts(true));
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, '3.3');
    await tester.pump();
    await tester.tap(find.text('Save Count'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Review Count'), findsNothing);
    expect(find.textContaining('quarters'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  testWidgets('switch off: the box takes whole numbers only', (tester) async {
    await tester.runAsync(() => setParts(false));
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, '1.5');
    await tester.pump();
    // The dot is filtered out: a part cannot even be typed.
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '15',
    );
    await disposeScreen(tester);
  });

  testWidgets('history shows a saved part as a decimal', (tester) async {
    await tester.runAsync(
      () => env.db.stockCountsDao.recordCount(
        storeId: env.storeId,
        businessDate: '2026-10-01',
        productsCounted: 1,
        changedLines: [
          {
            'p': sample.productIds['Gulder'],
            'n': 'Gulder',
            's': 4,
            'a': 3.5,
            'd': -0.5,
          },
        ],
        countedBy: sample.staffId,
      ),
    );
    await pump(tester);
    await tester.tap(find.byTooltip('View History'));
    await settle(tester);
    await tester.tap(find.text('Oct 1, 2026'));
    await tester.pumpAndSettle();
    expect(find.text('4 → 3.5'), findsOneWidget);
    expect(find.text('-0.5'), findsOneWidget);
    await disposeScreen(tester);
  });
}
