import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Seeds two stores and a product with [initialStock] in the source store.
/// Returns ids for use in transfer calls.
Future<
    ({
      String fromStoreId,
      String toStoreId,
      String productId,
      String staffId,
    })>
_seed(
  AppDatabase db,
  String businessId, {
  int initialStock = 10,
}) async {
  final fromStoreId = UuidV7.generate();
  final toStoreId = UuidV7.generate();

  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(fromStoreId),
          businessId: businessId,
          name: 'Source Store',
        ),
      );
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(toStoreId),
          businessId: businessId,
          name: 'Dest Store',
        ),
      );

  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'CEO',
          pin: '0000',
        ),
      );

  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Stout',
          retailerPriceKobo: const Value(120000),
        ),
      );

  if (initialStock > 0) {
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: fromStoreId,
            quantity: Value(initialStock),
          ),
        );
  }

  return (
    fromStoreId: fromStoreId,
    toStoreId: toStoreId,
    productId: productId,
    staffId: staffId,
  );
}

/// Reads the current inventory quantity for [productId] at [storeId].
Future<int> _stockAt(AppDatabase db, String productId, String storeId) async {
  final row = await (db.select(db.inventory)
        ..where(
          (t) => t.productId.equals(productId) & t.storeId.equals(storeId),
        ))
      .getSingleOrNull();
  return row?.quantity ?? 0;
}

/// Reads all stock_transactions referencing [transferId].
Future<List<StockTransactionData>> _txnsFor(
  AppDatabase db,
  String transferId,
) async {
  return (db.select(db.stockTransactions)
        ..where((t) => t.transferId.equals(transferId)))
      .get();
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // Use the local (flag-off) path so inventory changes happen synchronously
    // in the test process without a cloud round-trip.
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
  });

  tearDown(() => db.close());

  // ── Guards ────────────────────────────────────────────────────────────────

  group('createTransfer — guards', () {
    test('same-store throws ArgumentError', () async {
      final fx = await _seed(db, businessId);
      expect(
        () => db.stockTransferDao.createTransfer(
          fromStoreId: fx.fromStoreId,
          toStoreId: fx.fromStoreId,
          productId: fx.productId,
          quantity: 3,
          initiatedBy: fx.staffId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('zero quantity throws ArgumentError', () async {
      final fx = await _seed(db, businessId);
      expect(
        () => db.stockTransferDao.createTransfer(
          fromStoreId: fx.fromStoreId,
          toStoreId: fx.toStoreId,
          productId: fx.productId,
          quantity: 0,
          initiatedBy: fx.staffId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('insufficient stock throws InsufficientStockException', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      expect(
        () => db.stockTransferDao.createTransfer(
          fromStoreId: fx.fromStoreId,
          toStoreId: fx.toStoreId,
          productId: fx.productId,
          quantity: 10,
          initiatedBy: fx.staffId,
        ),
        throwsA(isA<InsufficientStockException>()),
      );
    });
  });

  // ── Create → Receive ──────────────────────────────────────────────────────

  group('createTransfer + receiveTransfer round-trip', () {
    test('source decremented at dispatch; dest stays zero until receipt',
        () async {
      final fx = await _seed(db, businessId, initialStock: 10);

      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 4,
        initiatedBy: fx.staffId,
      );

      // After dispatch: source −4, dest still 0.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(0));

      // Header status is in_transit.
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('in_transit'));

      await db.stockTransferDao.receiveTransfer(
        transferId: transferId,
        receivedBy: fx.staffId,
      );

      // After receipt: source unchanged, dest +4.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(4));

      // Header flipped to received.
      final received = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(received.status, equals('received'));
      expect(received.receivedBy, equals(fx.staffId));
    });

    test('correct movement types on ledger rows', () async {
      final fx = await _seed(db, businessId, initialStock: 8);

      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 3,
        initiatedBy: fx.staffId,
      );

      await db.stockTransferDao.receiveTransfer(
        transferId: transferId,
        receivedBy: fx.staffId,
      );

      final txns = await _txnsFor(db, transferId);
      expect(txns, hasLength(2));

      final outLeg = txns.firstWhere((t) => t.movementType == 'transfer_out');
      expect(outLeg.quantityDelta, equals(-3));
      expect(outLeg.locationId, equals(fx.fromStoreId));

      final inLeg = txns.firstWhere((t) => t.movementType == 'transfer_in');
      expect(inLeg.quantityDelta, equals(3));
      expect(inLeg.locationId, equals(fx.toStoreId));
    });

    test('receiving a non-in_transit transfer throws StateError', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 2,
        initiatedBy: fx.staffId,
      );
      await db.stockTransferDao.receiveTransfer(
        transferId: transferId,
        receivedBy: fx.staffId,
      );
      // Receiving again (already received) must throw.
      expect(
        () => db.stockTransferDao.receiveTransfer(
          transferId: transferId,
          receivedBy: fx.staffId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── Create → Cancel ───────────────────────────────────────────────────────

  group('createTransfer + cancelTransfer round-trip', () {
    test('cancel restores source inventory', () async {
      final fx = await _seed(db, businessId, initialStock: 10);

      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 6,
        initiatedBy: fx.staffId,
      );

      // After dispatch: source = 4.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(4));

      await db.stockTransferDao.cancelTransfer(
        transferId: transferId,
        cancelledBy: fx.staffId,
      );

      // After cancel: source restored to 10, dest still 0.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(10));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(0));

      final cancelled = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(cancelled.status, equals('cancelled'));
    });

    test('cancel compensating leg uses transfer_in movement type', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 5,
        initiatedBy: fx.staffId,
      );
      await db.stockTransferDao.cancelTransfer(
        transferId: transferId,
        cancelledBy: fx.staffId,
      );

      final txns = await _txnsFor(db, transferId);
      // Dispatch (transfer_out) + compensating cancel (transfer_in at source).
      expect(txns, hasLength(2));
      final outLeg = txns.firstWhere((t) => t.movementType == 'transfer_out');
      expect(outLeg.locationId, equals(fx.fromStoreId));
      final compensate = txns.firstWhere((t) => t.movementType == 'transfer_in');
      expect(compensate.locationId, equals(fx.fromStoreId));
      expect(compensate.quantityDelta, equals(5));
    });

    test('cancelling a non-in_transit transfer throws StateError', () async {
      final fx = await _seed(db, businessId, initialStock: 3);
      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 3,
        initiatedBy: fx.staffId,
      );
      await db.stockTransferDao.cancelTransfer(
        transferId: transferId,
        cancelledBy: fx.staffId,
      );
      // Cancelling again (already cancelled) must throw.
      expect(
        () => db.stockTransferDao.cancelTransfer(
          transferId: transferId,
          cancelledBy: fx.staffId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── Header enqueued for sync ──────────────────────────────────────────────

  group('sync enqueue', () {
    test('createTransfer enqueues the stock_transfers row', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      await db.stockTransferDao.createTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 2,
        initiatedBy: fx.staffId,
      );

      final queue = await getPendingQueue(db);
      final transferUpsert = queue.where(
        (q) => q.actionType == 'stock_transfers:upsert',
      );
      expect(transferUpsert, isNotEmpty);
    });
  });
}
