// Visual goldens for Request Stock (#380; first pinned in #362 PR 2):
//
// - `request_stock_neither_fixed_390x844_*`: Home's Stock Transfer tile under
//   All Stores — both store pickers, nothing chosen yet, so the "choose the
//   store" empty state.
// - `request_stock_empty_{390x844,844x390}_*`: "Deliver to" fixed (a locked
//   store), Lekki chosen as the source: its in-stock products as tiles with
//   their stock, the coach hint, nothing on the request yet (no bar).
// - `request_stock_list_{390x844,844x390}_*`: three products on the request
//   and the review sheet open: a stepper and remove per line, "Send request".
//
// Light + dark. A business with two stores and a van (the van is never
// offered). The long product name ellipsizes. Pushed full screen, no system
// insets (the frame owns those). Regenerate with:
//
//     flutter test --update-goldens test/redesign/request_stock_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/request_product_grid.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StoreData abuja;
  late StoreData lekki;
  late List<String> lekkiProducts;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    final lekkiId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(lekkiId),
            businessId: env.businessId,
            name: 'Lekki',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            name: 'Van 1',
            kind: const Value(kStoreKindVan),
          ),
        );
    lekki = (await db.storesDao.getStore(lekkiId))!;
    abuja = (await db.storesDao.getStore(env.storeId))!;

    final categories = <String, String>{};
    for (final name in ['Beer', 'Malt', 'Water', 'Stout']) {
      final id = UuidV7.generate();
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
            ),
          );
      categories[name] = id;
    }
    lekkiProducts = [];
    for (final (name, category, size, unit, stock) in [
      ('Star Lager', 'Beer', '60cl', 'Bottle', 48),
      ('Malta Guinness', 'Malt', '33cl', 'Can', 4),
      (
        'Guinness Foreign Extra Stout Big Bottle Party Pack',
        'Stout',
        '60cl',
        'Bottle',
        120,
      ),
      ('Eva Water', 'Water', '75cl', 'Bottle', 36),
      ('Hero Lager', 'Beer', '60cl', 'Bottle', 0),
    ]) {
      final id = UuidV7.generate();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
              categoryId: Value(categories[category]),
              subtitle: Value(size),
              unit: Value(unit),
            ),
          );
      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              storeId: lekkiId,
              productId: id,
              quantity: Value(stock),
            ),
          );
      lekkiProducts.add(id);
    }
  });

  tearDown(() => env.dispose());

  // The list goldens capture the whole navigator (screen + sheet), which the
  // harness's debug banner would otherwise draw over.
  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> open(
    WidgetTester tester, {
    required Size size,
    required Brightness brightness,
    required Widget screen,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: EdgeInsets.zero,
      screen: _Launcher(screen: screen),
      bottomNavHeight: 0,
      grantedKeys: const {'stores.request_transfer', 'stock.view'},
      roleRank: 0,
      selectableStores: [abuja, lekki],
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      settle: false,
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Future<void> pickLekki(WidgetTester tester) async {
    await tester.tap(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('Request from store'),
              matching: find.byWidgetPredicate((w) => w is FormField),
            ),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lekki').last);
    await settle(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('request stock, neither fixed, 390x844 $themeName', (
      tester,
    ) async {
      await open(
        tester,
        size: const Size(390, 844),
        brightness: brightness,
        screen: const RequestStockScreen(),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(RequestStockScreen),
        matchesGoldenFile(
          'goldens/request_stock_neither_fixed_390x844_$themeName.png',
        ),
      );
      await disposeScreen(tester);
    });

    for (final size in const [Size(390, 844), Size(844, 390)]) {
      final sizeName = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('request stock, empty list, $sizeName $themeName', (
        tester,
      ) async {
        await open(
          tester,
          size: size,
          brightness: brightness,
          screen: RequestStockScreen(fixedDestStoreId: abuja.id),
        );
        await pickLekki(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(RequestStockScreen),
          matchesGoldenFile(
            'goldens/request_stock_empty_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('request stock, 3 lines in review, $sizeName $themeName', (
        tester,
      ) async {
        await open(
          tester,
          size: size,
          brightness: brightness,
          screen: RequestStockScreen(fixedDestStoreId: abuja.id),
        );
        await pickLekki(tester);
        for (final (i, taps) in [(0, 6), (1, 1), (2, 12)]) {
          final tile = find.byKey(requestProductTileKey(lekkiProducts[i]));
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          for (var t = 0; t < taps; t++) {
            await tester.tap(tile);
            await tester.pump();
          }
        }
        // Let the fly-to animations land.
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byKey(RequestStockKeys.reviewBar));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          // The root navigator: the screen plus the sheet over it.
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/request_stock_list_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}

/// Opens Request Stock from a page that already watches the stores, as Home
/// does (the screen reads them once when it starts).
class _Launcher extends ConsumerWidget {
  const _Launcher({required this.screen});

  final Widget screen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(allStoresProvider);
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => screen)),
          child: const Text('open'),
        ),
      ),
    );
  }
}
