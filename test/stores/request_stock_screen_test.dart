// Request Stock (#380, PRD #346 Wave 1): pick several products like POS.
//
// Store rules carried over from #362 PR 2: at most one fixed store; with
// neither fixed both pickers show, vans are never offered and the two ends
// must differ. The picker shows only the source store's in-stock products;
// tap adds one, tap and hold sets a quantity, the review sheet steps / removes
// lines (never below 1), and Send confirms then writes one pending row per
// product. Changing the source store clears the list, after asking.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/request_product_grid.dart';
import 'package:reebaplus_pos/features/stores/widgets/stock_request_quantity_sheet.dart';
import 'package:reebaplus_pos/features/stores/widgets/stock_request_review_sheet.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StoreData ikeja;
  late String p1;
  late String p2;
  late String p3;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 3);
    final db = env.db;
    p1 = env.products[0].id;
    p2 = env.products[1].id;
    p3 = env.products[2].id;
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
    // Ikeja holds 30 of Product 1, 12 of Product 2 and none of Product 3.
    for (final (id, qty) in [(p1, 30), (p2, 12), (p3, 0)]) {
      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              storeId: ikejaId,
              productId: id,
              quantity: Value(qty),
            ),
          );
    }
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
  Future<void> pumpRequest(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    TextScaler? textScaler,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      textScaler: textScaler,
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

  Future<void> pick(WidgetTester tester, String label, String store) async {
    await openOptions(tester, label);
    await tester.tap(find.text(store).last);
    await deliver(tester);
  }

  Finder tile(String id) => find.byKey(requestProductTileKey(id));

  Future<void> tapTile(WidgetTester tester, String id, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await tester.tap(tile(id));
      await tester.pump();
    }
    await deliver(tester);
  }

  Future<void> openReview(WidgetTester tester) async {
    await tester.tap(find.byKey(RequestStockKeys.reviewBar));
    await tester.pumpAndSettle();
    expect(find.byKey(StockRequestReviewKeys.sheet), findsOneWidget);
  }

  String stepperQty(String id) {
    final line = find.byKey(StockRequestReviewKeys.line(id));
    final texts = find.descendant(of: line, matching: find.byType(Text));
    // The stepper's number is the last Text in the line.
    return (texts.evaluate().last.widget as Text).data!;
  }

  Future<List<StockTransferData>> requests(WidgetTester tester) async =>
      (await tester.runAsync(
        () => env.db.select(env.db.stockTransfers).get(),
      ))!;

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

  testWidgets('neither fixed: both pickers, no van, the ends differ, and one '
      'send writes a pending row per product', (tester) async {
    await pumpRequest(tester, const RequestStockScreen());
    expect(dropdown('Request from store'), findsOneWidget);
    expect(dropdown('Deliver to store'), findsOneWidget);
    // Nothing to pick from until the source is chosen.
    expect(find.byKey(RequestStockKeys.emptyState), findsOneWidget);

    // Source list: every non-van store.
    await openOptions(tester, 'Request from store');
    expect(find.text('Main Store'), findsOneWidget);
    expect(find.text('Ikeja'), findsOneWidget);
    expect(find.text('Van 1'), findsNothing);
    await tester.tap(find.text('Ikeja').last);
    await deliver(tester);

    // Destination list now leaves out the source.
    await openOptions(tester, 'Deliver to store');
    expect(find.text('Van 1'), findsNothing);
    expect(find.text('Ikeja'), findsOneWidget);
    await tester.tap(find.text('Main Store').last);
    await deliver(tester);

    await tapTile(tester, p1, times: 2);
    await tapTile(tester, p2);
    expect(find.text('2 items · Review request'), findsOneWidget);

    await openReview(tester);
    expect(find.text('From Ikeja to Main Store'), findsOneWidget);
    expect(find.text('2 products · 3 units'), findsOneWidget);
    await tester.tap(find.byKey(StockRequestReviewKeys.send));
    await tester.pumpAndSettle();

    // The confirmation step.
    expect(find.text('Send this request?'), findsOneWidget);
    expect(find.text('2 products, 3 units'), findsOneWidget);
    expect(await requests(tester), isEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.text('Send request'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await deliver(tester);
    expect(find.textContaining('Could not send'), findsNothing);

    final rows = await requests(tester);
    expect({for (final r in rows) r.productId: r.quantity}, {p1: 2, p2: 1});
    for (final r in rows) {
      expect(r.fromLocationId, ikeja.id);
      expect(r.toLocationId, env.storeId);
      expect(r.status, 'pending');
    }
    // Sent: back to where the user came from.
    expect(find.byType(RequestStockScreen), findsNothing);
    expect(
      find.text('Request sent to Ikeja — awaiting dispatch.'),
      findsOneWidget,
    );
    // Let the notification's dismiss timer run out.
    await tester.pump(const Duration(seconds: 5));
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

  testWidgets('only the source store\'s in-stock products, with its stock', (
    tester,
  ) async {
    await pumpRequest(
      tester,
      RequestStockScreen(fixedDestStoreId: env.storeId),
    );
    await pick(tester, 'Request from store', 'Ikeja');
    expect(tile(p1), findsOneWidget);
    expect(tile(p2), findsOneWidget);
    expect(tile(p3), findsNothing, reason: 'Ikeja has none of Product 3');
    expect(
      find.descendant(of: tile(p1), matching: find.text('30 in stock')),
      findsOneWidget,
    );
    expect(find.byKey(RequestStockKeys.hint), findsOneWidget);

    // Search narrows the grid.
    await tester.enterText(find.byKey(RequestStockKeys.search), 'Product 2');
    await deliver(tester);
    expect(tile(p1), findsNothing);
    expect(tile(p2), findsOneWidget);
    await tester.enterText(find.byKey(RequestStockKeys.search), 'zzz');
    await deliver(tester);
    expect(find.text('No products match "zzz".'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('tap adds one each time; tap and hold sets a quantity', (
    tester,
  ) async {
    await pumpRequest(
      tester,
      RequestStockScreen(fixedDestStoreId: env.storeId),
    );
    await pick(tester, 'Request from store', 'Ikeja');
    expect(find.byKey(RequestStockKeys.reviewBar), findsNothing);
    await tapTile(tester, p1);
    expect(find.text('1 item · Review request'), findsOneWidget);
    await tapTile(tester, p1);
    // The tile's badge counts what is on the request.
    expect(
      find.descendant(of: tile(p1), matching: find.text('2')),
      findsOneWidget,
    );

    await tester.longPress(tile(p2));
    await tester.pumpAndSettle();
    expect(find.text('Ikeja has 12'), findsOneWidget);
    // Zero is refused in plain words.
    await tester.enterText(
      find.byKey(StockRequestQuantitySheetKeys.field),
      '0',
    );
    await tester.tap(find.byKey(StockRequestQuantitySheetKeys.save));
    await tester.pump();
    expect(find.text('Enter a quantity greater than 0.'), findsOneWidget);
    await tester.enterText(
      find.byKey(StockRequestQuantitySheetKeys.field),
      '7',
    );
    await tester.tap(find.byKey(StockRequestQuantitySheetKeys.save));
    await tester.pumpAndSettle();
    expect(find.text('2 items · Review request'), findsOneWidget);
    expect(
      find.descendant(of: tile(p2), matching: find.text('7')),
      findsOneWidget,
    );

    // Holding again starts from what is already on the request.
    await tester.longPress(tile(p2));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(StockRequestQuantitySheetKeys.field),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '7',
    );
    await disposeScreen(tester);
  });

  testWidgets('review: the stepper steps, never below 1 (remove instead), '
      'remove drops a line, and the last one closes the sheet', (tester) async {
    await pumpRequest(
      tester,
      RequestStockScreen(fixedDestStoreId: env.storeId),
    );
    await pick(tester, 'Request from store', 'Ikeja');
    await tapTile(tester, p1, times: 2);
    await tapTile(tester, p2);
    await openReview(tester);

    final p1Line = find.byKey(StockRequestReviewKeys.line(p1));
    Finder stepper(String key) =>
        find.descendant(of: p1Line, matching: find.byKey(Key('stepper-$key')));
    expect(stepperQty(p1), '2');
    await tester.tap(stepper('increment'));
    await tester.pump();
    expect(stepperQty(p1), '3');
    await tester.tap(stepper('decrement'));
    await tester.pump();
    await tester.tap(stepper('decrement'));
    await tester.pump();
    expect(stepperQty(p1), '1');
    // At 1 the minus is "Remove": the line goes rather than reaching 0.
    expect(
      find.descendant(of: p1Line, matching: find.byTooltip('Remove')),
      findsNWidgets(2),
    );
    await tester.tap(stepper('decrement'));
    await tester.pumpAndSettle();
    expect(p1Line, findsNothing);
    expect(find.text('1 product · 1 unit'), findsOneWidget);

    // The remove button; the last line closes the sheet.
    await tester.tap(find.byKey(StockRequestReviewKeys.remove(p2)));
    await tester.pumpAndSettle();
    expect(find.byKey(StockRequestReviewKeys.sheet), findsNothing);
    expect(find.byType(RequestStockScreen), findsOneWidget);
    expect(find.byKey(RequestStockKeys.reviewBar), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('changing the source asks first, then clears the list', (
    tester,
  ) async {
    await pumpRequest(tester, const RequestStockScreen());
    await pick(tester, 'Request from store', 'Ikeja');
    await tapTile(tester, p1);
    expect(find.text('1 item · Review request'), findsOneWidget);

    // Backing out keeps the list and the store.
    await pick(tester, 'Request from store', 'Main Store');
    expect(find.text('Change the store?'), findsOneWidget);
    expect(
      find.textContaining('Your list has 1 product from Ikeja'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep list'));
    await deliver(tester);
    expect(find.text('1 item · Review request'), findsOneWidget);
    expect(
      find.descendant(
        of: dropdown('Request from store'),
        matching: find.text('Ikeja'),
      ),
      findsOneWidget,
    );

    // Going ahead clears it and shows the new store's products.
    await pick(tester, 'Request from store', 'Main Store');
    await tester.tap(find.text('Clear and change'));
    await deliver(tester);
    expect(find.byKey(RequestStockKeys.reviewBar), findsNothing);
    expect(tile(p3), findsOneWidget, reason: 'Main Store has Product 3');

    // An empty list changes store without asking.
    await pick(tester, 'Request from store', 'Ikeja');
    expect(find.text('Change the store?'), findsNothing);
    expect(tile(p3), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('send without a destination says so and writes nothing', (
    tester,
  ) async {
    await pumpRequest(tester, const RequestStockScreen());
    await pick(tester, 'Request from store', 'Ikeja');
    await tapTile(tester, p1);
    await openReview(tester);
    await tester.tap(find.byKey(StockRequestReviewKeys.send));
    await tester.pumpAndSettle();
    expect(find.text('Please select which store needs it.'), findsOneWidget);
    expect(find.text('Send this request?'), findsNothing);
    expect(await requests(tester), isEmpty);
    // The list is kept for when they pick the destination.
    expect(find.text('1 item · Review request'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  testWidgets('cancelling the confirmation writes nothing', (tester) async {
    await pumpRequest(
      tester,
      RequestStockScreen(fixedDestStoreId: env.storeId),
    );
    await pick(tester, 'Request from store', 'Ikeja');
    await tapTile(tester, p2);
    await openReview(tester);
    await tester.tap(find.byKey(StockRequestReviewKeys.send));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await requests(tester), isEmpty);
    expect(find.text('1 item · Review request'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets(
    'requestStoreTransfer gate denial blocks sending and shows feedback',
    (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        screen: _Launcher(
          screen: RequestStockScreen(fixedDestStoreId: env.storeId),
        ),
        bottomNavHeight: 0,
        grantedKeys: const {'stock.view'}, // lacks stores.request_transfer
        roleRank: 0,
        selectableStores: [env.store, ikeja],
        settle: false,
      );
      await deliver(tester);
      await tester.tap(find.text('open'));
      await deliver(tester);

      await pick(tester, 'Request from store', 'Ikeja');
      await tapTile(tester, p1);
      await openReview(tester);

      await tester.tap(find.byKey(StockRequestReviewKeys.send));
      await tester.pump();

      expect(
        find.text('You no longer have access to Request Stock Transfer.'),
        findsOneWidget,
      );
      expect(find.text('Send this request?'), findsNothing);
      expect(await requests(tester), isEmpty);
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    },
  );

  group('fits every size: no overflow, long names ellipsize, 48dp targets', () {
    for (final (name, size, scale) in const [
      ('360x740 @1.3', Size(360, 740), 1.3),
      ('390x844', Size(390, 844), 1.0),
      ('844x390', Size(844, 390), 1.0),
      ('844x390 @1.3', Size(844, 390), 1.3),
      ('800x1280', Size(800, 1280), 1.0),
      ('1280x800', Size(1280, 800), 1.0),
    ]) {
      testWidgets(name, (tester) async {
        await tester.runAsync(
          () => (env.db.update(env.db.products)..where((t) => t.id.equals(p1)))
              .write(
                const ProductsCompanion(
                  name: Value(
                    'Guinness Foreign Extra Stout Big Bottle Party Pack '
                    'Special Edition',
                  ),
                ),
              ),
        );
        await pumpRequest(
          tester,
          RequestStockScreen(fixedDestStoreId: env.storeId),
          size: size,
          textScaler: TextScaler.linear(scale),
        );
        await pick(tester, 'Request from store', 'Ikeja');
        expect(tester.takeException(), isNull);
        final name = find.descendant(
          of: tile(p1),
          matching: find.textContaining('Guinness'),
        );
        expect(
          tester.renderObject<RenderParagraph>(name).didExceedMaxLines,
          isTrue,
          reason: 'the long name ellipsizes on its tile',
        );
        final r = tester.getRect(tile(p1));
        expect(r.width, greaterThanOrEqualTo(kMinInteractiveDimension));
        expect(r.right, lessThanOrEqualTo(size.width));

        await tester.ensureVisible(tile(p1));
        await tester.pumpAndSettle();
        await tapTile(tester, p1);
        await tester.ensureVisible(tile(p2));
        await tester.pumpAndSettle();
        await tapTile(tester, p2);
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byKey(RequestStockKeys.reviewBar));
        expect(bar.height, greaterThanOrEqualTo(kMinInteractiveDimension));
        expect(bar.bottom, lessThanOrEqualTo(size.height));

        await openReview(tester);
        expect(tester.takeException(), isNull);
        final send = tester.getRect(find.byKey(StockRequestReviewKeys.send));
        expect(send.bottom, lessThanOrEqualTo(size.height));
        await disposeScreen(tester);
      });
    }
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
