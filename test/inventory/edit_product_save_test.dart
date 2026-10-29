// Edit Product saves (#487 PR 4): the Add Product form in edit mode does what
// the old Edit pop-up did (details, cost 0 -> real follow-up, activity log),
// and a CLEARED box reaches the outbox as an explicit null.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/listing_content_fields.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

const _grants = {...kInventorySampleGrants, 'products.edit_buying_price'};

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    docs = Directory.systemTemp.createTempSync('edit_product_save');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
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
    // The signed-in test user, so the activity log's staff link resolves.
    await env.db
        .into(env.db.users)
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

  String idOf(String name) => sample.productIds[name]!;

  Future<ProductData> row(String id) => (env.db.select(
    env.db.products,
  )..where((p) => p.id.equals(id))).getSingle();

  Future<void> open(WidgetTester tester, String id,
      {Set<String> grants = _grants}) async {
    final product = await row(id);
    const insets = FakeViewPadding(top: 24, bottom: 24);
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: AddProductScreen(editProduct: product),
      followView: true,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> type(WidgetTester tester, Key key, String text) async {
    final box = find.descendant(
      of: find.byKey(key),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(box);
    await tester.enterText(box, text);
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    final button = find.byKey(AddProductKeys.save);
    await tester.ensureVisible(button);
    await tester.tap(button);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Let the success notice's timer run out.
    await tester.pump(const Duration(seconds: 6));
  }

  Future<Map<String, dynamic>> pendingProduct(String id) async {
    final rows = (await getPendingQueue(env.db))
        .where((q) => q.actionType == 'products:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == id)
        .toList();
    expect(rows, hasLength(1), reason: 'the outbox coalesces to one row');
    return rows.single;
  }

  testWidgets('saves the details through the same DAO path and logs it', (
    tester,
  ) async {
    final id = idOf('Coca-Cola');
    await open(tester, id);
    await type(tester, AddProductKeys.name, 'Coca-Cola Zero');
    await type(tester, AddProductKeys.retail, '700');
    await type(tester, AddProductKeys.lowStock, '9');
    await save(tester);

    final saved = await row(id);
    expect(saved.name, 'Coca-Cola Zero');
    expect(saved.retailerPriceKobo, 70000);
    expect(saved.lowStockThreshold, 9);
    final payload = await pendingProduct(id);
    expect(payload['name'], 'Coca-Cola Zero');
    final logs = await env.db.select(env.db.activityLogs).get();
    expect(logs.where((l) => l.action == 'update_product'), isNotEmpty);
    await disposeScreen(tester);
  });

  testWidgets('cost going 0 -> real costs the uncosted batch', (tester) async {
    final id = idOf('Coca-Cola');
    expect((await row(id)).buyingPriceKobo, 0);
    final batchId = UuidV7.generate();
    await env.db
        .into(env.db.costBatches)
        .insert(
          CostBatchesCompanion.insert(
            id: Value(batchId),
            businessId: env.businessId,
            productId: id,
            storeId: env.storeId,
            qtyRemaining: 20,
            qtyOriginal: 20,
            costKobo: const Value(0),
            receivedAt: Value(DateTime.utc(2026, 1, 1)),
          ),
        );
    await open(tester, id);
    await type(tester, AddProductKeys.cost, '300');
    await save(tester);

    expect((await row(id)).buyingPriceKobo, 30000);
    final batch = await (env.db.select(
      env.db.costBatches,
    )..where((b) => b.id.equals(batchId))).getSingle();
    expect(batch.costKobo, 30000, reason: 'onCostBecameReal ran');
    await disposeScreen(tester);
  });

  testWidgets(
    'a cleared units-per-pack, description and barcode push as null',
    (tester) async {
      final id = idOf('Coca-Cola');
      await env.db.catalogDao.updateProductDetails(
        id,
        name: 'Coca-Cola',
        buyingPriceKobo: 0,
        retailerPriceKobo: 60000,
        wholesalerPriceKobo: 55000,
        unit: 'Bottle',
        unitsPerPack: 12,
        subtitle: 'Classic',
        barcode: '12345',
      );
      // Drop the setup write's outbox row so only the form's save is checked.
      await env.db.delete(env.db.syncQueue).go();
      await open(tester, id);
      await type(tester, AddProductKeys.unitsPerPack, '');
      await type(tester, AddProductKeys.description, '');
      await type(tester, AddProductKeys.barcode, '');
      await save(tester);

      final saved = await row(id);
      expect(saved.unitsPerPack, isNull);
      expect(saved.subtitle, isNull);
      expect(saved.barcode, isNull);
      final payload = await pendingProduct(id);
      for (final key in ['units_per_pack', 'subtitle', 'barcode']) {
        expect(payload.containsKey(key), isTrue, reason: '$key must be pushed');
        expect(payload[key], isNull, reason: '$key pushes as null');
      }
      expect(payload['name'], 'Coca-Cola', reason: 'it is the full row');
      await disposeScreen(tester);
    },
  );

  group('Online listing section (#473)', () {
    const listingGrants = {..._grants, 'products.manage_listing'};

    testWidgets('hidden without the listing grant', (tester) async {
      await open(tester, idOf('Coca-Cola'));
      expect(find.byKey(AddProductKeys.listingCard), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('drink shop brand starts from the manufacturer; save writes the listing', (
      tester,
    ) async {
      final id = idOf('Coca-Cola');
      await open(tester, id, grants: listingGrants);
      expect(find.byKey(AddProductKeys.listingCard), findsOneWidget);
      final brand = find.descendant(of: find.byKey(ListingFieldKeys.brand),
        matching: find.byType(EditableText));
      await tester.ensureVisible(brand);
      expect(tester.widget<EditableText>(brand).controller.text, 'Coca-Cola HBC');
      await type(tester, ListingFieldKeys.description, 'Chilled 50cl bottles');
      await type(tester, ListingFieldKeys.orderStep, '12');
      await save(tester);
      final saved = await row(id);
      expect(saved.onlineDescription, 'Chilled 50cl bottles');
      expect(saved.brand, 'Coca-Cola HBC');
      expect((saved.minOrderQty, saved.orderStep, saved.maxOrderQty), (1, 12, null));
      final payload = await pendingProduct(id);
      expect(payload['order_step'], 12);
      await disposeScreen(tester);
    });

    testWidgets('an impossible order range stops the save', (tester) async {
      final id = idOf('Coca-Cola');
      await open(tester, id, grants: listingGrants);
      await type(tester, AddProductKeys.name, 'Coca-Cola Zero');
      await type(tester, ListingFieldKeys.minOrder, '10');
      await type(tester, ListingFieldKeys.maxOrder, '5');
      await save(tester);
      final saved = await row(id);
      expect(saved.name, 'Coca-Cola');
      expect(saved.minOrderQty, 1);
      await disposeScreen(tester);
    });
  });
}
