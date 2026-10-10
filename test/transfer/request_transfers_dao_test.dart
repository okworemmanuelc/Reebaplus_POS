// #380: Request Stock sends one request for several products. The DAO writes
// one `pending` stock_transfers row per product in ONE transaction — all saved
// or none — and notifies each recipient once for the whole submit.

import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String fromStoreId;
  late String toStoreId;
  late String requesterId;
  late String holderId;
  late List<String> productIds;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    Future<String> store(String name) async {
      final id = UuidV7.generate();
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
            ),
          );
      return id;
    }

    Future<String> user(String name) async {
      final id = UuidV7.generate();
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
              pin: '0000',
            ),
          );
      return id;
    }

    fromStoreId = await store('Ikeja');
    toStoreId = await store('Lekki');
    requesterId = await user('Requester');
    holderId = await user('Holder');
    // The holder works at the source store, so it is told about the request.
    await db
        .into(db.userStores)
        .insert(
          UserStoresCompanion.insert(
            businessId: businessId,
            userId: holderId,
            storeId: fromStoreId,
          ),
        );

    productIds = [];
    for (final name in ['Stout', 'Malt', 'Water']) {
      final id = UuidV7.generate();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
            ),
          );
      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: id,
              storeId: fromStoreId,
              quantity: const Value(20),
            ),
          );
      productIds.add(id);
    }
  });

  tearDown(() => db.close());

  Future<List<StockTransferData>> rows() => db.select(db.stockTransfers).get();

  Future<int> queuedTransfers() async => (await getPendingQueue(
    db,
  )).where((q) => q.actionType == 'stock_transfers:upsert').length;

  Future<List<NotificationData>> requestNotifications() => (db.select(
    db.notifications,
  )..where((n) => n.type.equals('stock_transfer.requested'))).get();

  test(
    'writes one pending row per product, in order, and queues each',
    () async {
      final ids = await db.stockTransferDao.requestTransfers(
        fromStoreId: fromStoreId,
        toStoreId: toStoreId,
        lines: [
          (productId: productIds[0], quantity: 3),
          (productId: productIds[1], quantity: 1),
          (productId: productIds[2], quantity: 12),
        ],
        requestedBy: requesterId,
      );

      expect(ids, hasLength(3));
      final saved = {for (final r in await rows()) r.id: r};
      expect(saved.keys.toSet(), ids.toSet());
      for (final (i, qty) in [(0, 3), (1, 1), (2, 12)]) {
        final r = saved[ids[i]]!;
        expect(r.productId, productIds[i]);
        expect(r.quantity, qty);
        expect(r.status, 'pending');
        expect(r.fromLocationId, fromStoreId);
        expect(r.toLocationId, toStoreId);
        expect(r.initiatedBy, requesterId);
      }
      // One submit: every row carries the same request time.
      expect(saved.values.map((r) => r.initiatedAt).toSet(), hasLength(1));
      expect(await queuedTransfers(), 3);

      // No stock moves until the holder dispatches.
      final stock = await db.select(db.inventory).get();
      expect(stock.every((s) => s.quantity == 20), isTrue);
    },
  );

  test('one notification per recipient for the whole submit', () async {
    final ids = await db.stockTransferDao.requestTransfers(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      lines: [
        (productId: productIds[0], quantity: 3),
        (productId: productIds[1], quantity: 2),
      ],
      requestedBy: requesterId,
    );
    final notes = await requestNotifications();
    final forHolder = notes.where((n) => n.recipientUserId == holderId);
    expect(forHolder, hasLength(1));
    expect(
      forHolder.single.message,
      'Stock request: 2 products (5 units) requested from your store.',
    );
    expect(forHolder.single.linkedRecordId, ids.first);
    // Never the requester.
    expect(notes.where((n) => n.recipientUserId == requesterId), isEmpty);
  });

  test('a one-line request notifies with the single-request wording', () async {
    await db.stockTransferDao.requestTransfers(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      lines: [(productId: productIds[0], quantity: 4)],
      requestedBy: requesterId,
    );
    final notes = await requestNotifications();
    expect(
      notes.single.message,
      'Stock request: 4 unit(s) requested from your store.',
    );
  });

  test(
    'all or nothing: a failing line leaves no row and nothing queued',
    () async {
      // The middle line names a product that does not exist: its insert fails
      // the foreign key AFTER the first line was written in the transaction.
      await expectLater(
        db.stockTransferDao.requestTransfers(
          fromStoreId: fromStoreId,
          toStoreId: toStoreId,
          lines: [
            (productId: productIds[0], quantity: 3),
            (productId: 'no-such-product', quantity: 1),
            (productId: productIds[2], quantity: 2),
          ],
          requestedBy: requesterId,
        ),
        throwsA(anything),
      );
      expect(await rows(), isEmpty);
      expect(await queuedTransfers(), 0);
      expect(await requestNotifications(), isEmpty);
    },
  );

  group('validated before anything is written', () {
    Future<void> expectRejected(
      List<StockRequestLine> lines, {
      String? to,
    }) async {
      await expectLater(
        db.stockTransferDao.requestTransfers(
          fromStoreId: fromStoreId,
          toStoreId: to ?? toStoreId,
          lines: lines,
          requestedBy: requesterId,
        ),
        throwsArgumentError,
      );
      expect(await rows(), isEmpty);
      expect(await queuedTransfers(), 0);
    }

    test('same store at both ends', () async {
      await expectRejected([
        (productId: productIds[0], quantity: 1),
      ], to: fromStoreId);
    });
    test('no lines', () async {
      await expectRejected(const []);
    });
    test('a zero quantity on any line', () async {
      await expectRejected([
        (productId: productIds[0], quantity: 2),
        (productId: productIds[1], quantity: 0),
      ]);
    });
    test('a negative quantity', () async {
      await expectRejected([(productId: productIds[0], quantity: -1)]);
    });
    test('the same product twice', () async {
      await expectRejected([
        (productId: productIds[0], quantity: 2),
        (productId: productIds[0], quantity: 1),
      ]);
    });
  });

  test('the single-product requestTransfer is unchanged', () async {
    final id = await db.stockTransferDao.requestTransfer(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      productId: productIds[1],
      quantity: 6,
      requestedBy: requesterId,
    );
    final r = (await rows()).single;
    expect(r.id, id);
    expect(r.quantity, 6);
    expect(r.status, 'pending');
    expect(await queuedTransfers(), 1);
    final notes = await requestNotifications();
    expect(
      notes.single.message,
      'Stock request: 6 unit(s) requested from your store.',
    );
  });
}
