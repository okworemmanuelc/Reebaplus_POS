// Visual golden for Request Stock with neither store fixed (#362 PR 2): Home's
// Stock Transfer tile under All Stores. Both pickers show ("Request from
// store", "Deliver to store"), then Product, Quantity and Send Request. The
// screen itself is not restyled here (Wave 2); this pins the new mode.
//
// 390x844, light + dark, a business with two stores and a van (the van is
// never offered). Regenerate with:
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

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StoreData abuja;
  late StoreData lekki;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 2,
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
  });

  tearDown(() => env.dispose());

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    testWidgets('request stock, neither fixed, 390x844 $themeName', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        padding: EdgeInsets.zero,
        screen: const _Launcher(),
        bottomNavHeight: 0,
        grantedKeys: const {'stores.request_transfer', 'stock.view'},
        roleRank: 0,
        selectableStores: [abuja, lekki],
        theme: brightness == Brightness.light
            ? AppTheme.light()
            : AppTheme.dark(),
        settle: false,
      );
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 250));
        }
      }

      await settle();
      await tester.tap(find.text('open'));
      await settle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(RequestStockScreen),
        matchesGoldenFile(
          'goldens/request_stock_neither_fixed_390x844_$themeName.png',
        ),
      );
      await disposeScreen(tester);
    });
  }
}

/// Opens Request Stock from a page that already watches the stores, as Home
/// does (the screen reads them once when it starts).
class _Launcher extends ConsumerWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(allStoresProvider);
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const RequestStockScreen()),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}
