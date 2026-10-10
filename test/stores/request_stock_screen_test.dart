// Request Stock's caller contract relaxed from "exactly one" to "at most one"
// fixed store (#362 PR 2, PRD #270 "Tile destinations"). With neither end
// fixed (Home's Stock Transfer tile under All Stores) both pickers show, vans
// are never offered, the two ends must differ and a request still posts. A
// fixed destination behaves as before.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StoreData ikeja;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 2);
    final db = env.db;
    final ikejaId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(ikejaId),
            businessId: env.businessId,
            name: 'Ikeja',
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
    // Ikeja holds 30 of Product 1.
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            storeId: ikejaId,
            productId: env.products.first.id,
            quantity: const Value(30),
          ),
        );
    ikeja = (await db.storesDao.getStore(ikejaId))!;
    // The harness's signed-in user, as a real row: a request records who
    // raised it (FK to users).
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  // Opened from a page that already watches the stores, as every real entry
  // point does (Home, the store page): the screen reads them once at start.
  Future<void> pumpRequest(WidgetTester tester, Widget screen) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: _Launcher(screen: screen),
      bottomNavHeight: 0,
      grantedKeys: const {'stores.request_transfer', 'stock.view'},
      roleRank: 0,
      selectableStores: [env.store, ikeja],
      settle: false,
    );
    await deliver(tester);
    await tester.tap(find.text('open'));
    await deliver(tester);
  }

  Finder dropdown(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is FormField),
  );

  Future<void> openOptions(WidgetTester tester, String label) async {
    await tester.tap(
      find
          .descendant(
            of: dropdown(label),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the constructor accepts neither, one, but not both', (
    tester,
  ) async {
    expect(() => const RequestStockScreen(), returnsNormally);
    expect(
      () => const RequestStockScreen(fixedDestStoreId: 'a'),
      returnsNormally,
    );
    expect(
      () => const RequestStockScreen(fixedSourceStoreId: 'a'),
      returnsNormally,
    );
    expect(
      () => RequestStockScreen(fixedDestStoreId: 'a', fixedSourceStoreId: 'b'),
      throwsAssertionError,
    );
  });

  testWidgets('neither fixed: both pickers, no van, and the ends differ', (
    tester,
  ) async {
    await pumpRequest(tester, const RequestStockScreen());
    expect(dropdown('Request from store'), findsOneWidget);
    expect(dropdown('Deliver to store'), findsOneWidget);

    // Source list: every non-van store.
    await openOptions(tester, 'Request from store');
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Ikeja'), findsOneWidget);
    expect(find.text('Van 1'), findsNothing);
    await tester.tap(find.text('Ikeja').last);
    await tester.pumpAndSettle();

    // Destination list now leaves out the source.
    await openOptions(tester, 'Deliver to store');
    expect(find.text('Van 1'), findsNothing);
    // "Ikeja" shows once (the chosen source), not as a destination option.
    expect(find.text('Ikeja'), findsOneWidget);
    await tester.tap(find.text('Main Store').last);
    await tester.pumpAndSettle();

    // Product + quantity, then send.
    await tester.enterText(find.byType(EditableText).first, 'Product 1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Product 1').last);
    await tester.pumpAndSettle();
    // The write is real Drift I/O: let it run on the real clock.
    await tester.runAsync(() async {
      await tester.tap(find.text('Send Request'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await deliver(tester);
    expect(find.textContaining('Could not send'), findsNothing);

    final rows = await tester.runAsync(
      () => env.db.select(env.db.stockTransfers).get(),
    );
    expect(rows, hasLength(1));
    expect(rows!.single.fromLocationId, ikeja.id);
    expect(rows.single.toLocationId, env.storeId);
    expect(rows.single.status, 'pending');
    await disposeScreen(tester);
  });

  testWidgets('destination fixed: "Deliver to" is locked, as before', (
    tester,
  ) async {
    await pumpRequest(
      tester,
      RequestStockScreen(fixedDestStoreId: env.storeId),
    );
    expect(dropdown('Request from store'), findsOneWidget);
    expect(dropdown('Deliver to store'), findsNothing);
    expect(find.text('Deliver to store'), findsOneWidget);
    expect(find.text('Main Store'), findsOneWidget);
    await openOptions(tester, 'Request from store');
    expect(find.text('Ikeja'), findsOneWidget);
    // The fixed destination is not offered as a source.
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Van 1'), findsNothing);
    await disposeScreen(tester);
  });
}

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
