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

  // ── Request → Dispatch → Receive (requester-initiated flow) ────────────────

  group('requestTransfer — guards', () {
    test('same-store throws ArgumentError', () async {
      final fx = await _seed(db, businessId);
      expect(
        () => db.stockTransferDao.requestTransfer(
          fromStoreId: fx.fromStoreId,
          toStoreId: fx.fromStoreId,
          productId: fx.productId,
          quantity: 3,
          requestedBy: fx.staffId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('zero quantity throws ArgumentError', () async {
      final fx = await _seed(db, businessId);
      expect(
        () => db.stockTransferDao.requestTransfer(
          fromStoreId: fx.fromStoreId,
          toStoreId: fx.toStoreId,
          productId: fx.productId,
          quantity: 0,
          requestedBy: fx.staffId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('requestTransfer + dispatchTransfer + receiveTransfer round-trip', () {
    test('request moves no stock; dispatch decrements source; receive credits '
        'dest', () async {
      final fx = await _seed(db, businessId, initialStock: 10);

      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 4,
        requestedBy: fx.staffId,
      );

      // After request: nothing moved, header is pending.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(10));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(0));
      var header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('pending'));
      expect(header.initiatedBy, equals(fx.staffId));

      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
      );

      // After dispatch: source −4, dest still 0, header in_transit.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(0));
      header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('in_transit'));

      await db.stockTransferDao.receiveTransfer(
        transferId: transferId,
        receivedBy: fx.staffId,
      );

      // After receipt: dest +4.
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(4));
      header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('received'));
    });

    test('dispatch can alter the quantity to match availability', () async {
      final fx = await _seed(db, businessId, initialStock: 10);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 8,
        requestedBy: fx.staffId,
      );

      // Holder only sends 5 of the 8 requested.
      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
        quantity: 5,
      );

      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(5));
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.quantity, equals(5));
      expect(header.status, equals('in_transit'));
    });

    test('dispatch with insufficient stock throws and leaves it pending',
        () async {
      final fx = await _seed(db, businessId, initialStock: 3);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 10,
        requestedBy: fx.staffId,
      );
      await expectLater(
        db.stockTransferDao.dispatchTransfer(
          transferId: transferId,
          dispatchedBy: fx.staffId,
        ),
        throwsA(isA<InsufficientStockException>()),
      );
      // Source untouched; header still pending (transaction rolled back).
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(3));
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('pending'));
    });

    test('dispatching a non-pending transfer throws StateError', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 2,
        requestedBy: fx.staffId,
      );
      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
      );
      expect(
        () => db.stockTransferDao.dispatchTransfer(
          transferId: transferId,
          dispatchedBy: fx.staffId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('rejectRequest', () {
    test('reject flips pending → cancelled and moves no stock', () async {
      final fx = await _seed(db, businessId, initialStock: 7);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 3,
        requestedBy: fx.staffId,
      );

      await db.stockTransferDao.rejectRequest(
        transferId: transferId,
        rejectedBy: fx.staffId,
      );

      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(7));
      expect(await _stockAt(db, fx.productId, fx.toStoreId), equals(0));
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('cancelled'));
    });

    test('rejecting a non-pending transfer throws StateError', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 2,
        requestedBy: fx.staffId,
      );
      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
      );
      expect(
        () => db.stockTransferDao.rejectRequest(
          transferId: transferId,
          rejectedBy: fx.staffId,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pending request enqueue', () {
    test('requestTransfer enqueues the stock_transfers row', () async {
      final fx = await _seed(db, businessId, initialStock: 5);
      await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 2,
        requestedBy: fx.staffId,
      );
      final queue = await getPendingQueue(db);
      expect(
        queue.where((q) => q.actionType == 'stock_transfers:upsert'),
        isNotEmpty,
      );
    });
  });

  group('dispatchTransfer with emptyCratesToSend', () {
    test('dispatch with emptyCratesToSend > 0 on crate-eligible product', () async {
      final fx = await _seed(db, businessId, initialStock: 10);

      // Seed manufacturer
      final mfrId = UuidV7.generate();
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: businessId,
              name: 'Coca Cola',
              depositAmountKobo: const Value(50000),
            ),
          );

      // Update product to be crate eligible
      await (db.update(db.products)..where((t) => t.id.equals(fx.productId))).write(
        ProductsCompanion(
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: Value(mfrId),
        ),
      );

      // Seed initial empty balances
      await db.into(db.storeCrateBalances).insert(
            StoreCrateBalancesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              storeId: fx.fromStoreId,
              manufacturerId: mfrId,
              balance: const Value(15),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
      await db.into(db.storeCrateBalances).insert(
            StoreCrateBalancesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              storeId: fx.toStoreId,
              manufacturerId: mfrId,
              balance: const Value(5),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 4,
        requestedBy: fx.staffId,
      );

      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
        emptyCratesToSend: 5,
      );

      // Verify header and stock
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('in_transit'));
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));

      // Verify crate ledger entries
      final ledgers = await db.select(db.crateLedger).get();
      expect(ledgers, hasLength(2));
      final outLedger = ledgers.firstWhere((l) => l.movementType == 'transferred_out');
      expect(outLedger.storeId, equals(fx.fromStoreId));
      expect(outLedger.quantityDelta, equals(-5));
      expect(outLedger.manufacturerId, equals(mfrId));

      final inLedger = ledgers.firstWhere((l) => l.movementType == 'transferred_in');
      expect(inLedger.storeId, equals(fx.toStoreId));
      expect(inLedger.quantityDelta, equals(5));
      expect(inLedger.manufacturerId, equals(mfrId));

      // Verify store crate balances
      final fromBal = await db.storeCrateBalancesDao.getBalance(
        storeId: fx.fromStoreId,
        manufacturerId: mfrId,
      );
      expect(fromBal, equals(10)); // 15 - 5

      final toBal = await db.storeCrateBalancesDao.getBalance(
        storeId: fx.toStoreId,
        manufacturerId: mfrId,
      );
      expect(toBal, equals(10)); // 5 + 5

      // Verify sync queue contains domain:pos_transfer_crates
      final queue = await getPendingQueue(db);
      expect(
        queue.where((q) => q.actionType == 'domain:pos_transfer_crates'),
        isNotEmpty,
      );
    });

    test('dispatch with emptyCratesToSend == 0 writes no crate movements', () async {
      final fx = await _seed(db, businessId, initialStock: 10);
      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 4,
        requestedBy: fx.staffId,
      );

      await db.stockTransferDao.dispatchTransfer(
        transferId: transferId,
        dispatchedBy: fx.staffId,
        emptyCratesToSend: 0,
      );

      // Verify stock updated normally
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(6));

      // Verify crate ledger and outbox are empty
      expect(await db.select(db.crateLedger).get(), isEmpty);
      final queue = await getPendingQueue(db);
      expect(
        queue.where((q) => q.actionType == 'domain:pos_transfer_crates'),
        isEmpty,
      );
    });

    test('dispatch with emptyCratesToSend > 0 on non-eligible product throws StateError and rolls back', () async {
      final fx = await _seed(db, businessId, initialStock: 10);

      // Update product to be NOT crate eligible (PET)
      await (db.update(db.products)..where((t) => t.id.equals(fx.productId))).write(
        const ProductsCompanion(
          unit: Value('PET'),
          trackEmpties: Value(false),
        ),
      );

      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 4,
        requestedBy: fx.staffId,
      );

      await expectLater(
        db.stockTransferDao.dispatchTransfer(
          transferId: transferId,
          dispatchedBy: fx.staffId,
          emptyCratesToSend: 5,
        ),
        throwsA(isA<StateError>()),
      );

      // Verify transaction rolled back: stock unchanged, header stays pending
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(10));
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('pending'));
      expect(await db.select(db.crateLedger).get(), isEmpty);
    });

    test('insufficient product stock with emptyCratesToSend > 0 throws InsufficientStockException and rolls back', () async {
      final fx = await _seed(db, businessId, initialStock: 3);

      // Seed manufacturer
      final mfrId = UuidV7.generate();
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: businessId,
              name: 'Coca Cola',
              depositAmountKobo: const Value(50000),
            ),
          );

      // Update product to be crate eligible
      await (db.update(db.products)..where((t) => t.id.equals(fx.productId))).write(
        ProductsCompanion(
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: Value(mfrId),
        ),
      );

      final transferId = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 10, // exceeds initial stock (3)
        requestedBy: fx.staffId,
      );

      await expectLater(
        db.stockTransferDao.dispatchTransfer(
          transferId: transferId,
          dispatchedBy: fx.staffId,
          emptyCratesToSend: 5,
        ),
        throwsA(isA<InsufficientStockException>()),
      );

      // Verify transaction rolled back
      expect(await _stockAt(db, fx.productId, fx.fromStoreId), equals(3));
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, equals('pending'));
      expect(await db.select(db.crateLedger).get(), isEmpty);
    });
  });

  group('StockTransferDao.watchHistoryForStore', () {
    test('filters by status received/cancelled, matches target store (both directions), excludes other stores/statuses, and sorts newest first', () async {
      final fx = await _seed(db, businessId);
      final storeC = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(storeC),
              businessId: businessId,
              name: 'Store C',
            ),
          );

      // Seed stock in B (toStoreId) at the start so we don't clash with receiveTransfer later
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: fx.productId,
              storeId: fx.toStoreId,
              quantity: const Value(10),
            ),
          );

      // Create several transfers with different statuses and stores:
      // 1. target Store A -> Dest Store B (status: received) -> Should include
      final t1 = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 1,
        requestedBy: fx.staffId,
      );
      await db.stockTransferDao.dispatchTransfer(
        transferId: t1,
        dispatchedBy: fx.staffId,
      );
      await db.stockTransferDao.receiveTransfer(
        transferId: t1,
        receivedBy: fx.staffId,
      );

      // 2. Dest Store B -> target Store A (status: cancelled) -> Should include
      final t2 = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.toStoreId,
        toStoreId: fx.fromStoreId,
        productId: fx.productId,
        quantity: 1,
        requestedBy: fx.staffId,
      );
      // Explicitly adjust initiatedAt of t2 to be 1 hour after t1 to guarantee descending order sorting
      final t1Data = await (db.select(db.stockTransfers)..where((t) => t.id.equals(t1))).getSingle();
      await (db.update(db.stockTransfers)..where((t) => t.id.equals(t2))).write(
        StockTransfersCompanion(
          initiatedAt: Value(t1Data.initiatedAt.add(const Duration(hours: 1))),
        ),
      );
      await db.stockTransferDao.rejectRequest( // rejects pending -> status cancelled
        transferId: t2,
        rejectedBy: fx.staffId,
      );

      // 3. target Store A -> Dest Store B (status: pending) -> Should exclude (active)
      final t3 = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 1,
        requestedBy: fx.staffId,
      );

      // 4. target Store A -> Dest Store B (status: in_transit) -> Should exclude (active)
      final t4 = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.fromStoreId,
        toStoreId: fx.toStoreId,
        productId: fx.productId,
        quantity: 1,
        requestedBy: fx.staffId,
      );
      await db.stockTransferDao.dispatchTransfer(
        transferId: t4,
        dispatchedBy: fx.staffId,
      );

      // 5. Store B -> Store C (status: received) -> Should exclude (target store A is not involved)
      final t5 = await db.stockTransferDao.requestTransfer(
        fromStoreId: fx.toStoreId,
        toStoreId: storeC,
        productId: fx.productId,
        quantity: 1,
        requestedBy: fx.staffId,
      );
      await db.stockTransferDao.dispatchTransfer(
        transferId: t5,
        dispatchedBy: fx.staffId,
      );
      await db.stockTransferDao.receiveTransfer(
        transferId: t5,
        receivedBy: fx.staffId,
      );

      // Now query watchHistoryForStore for Store A (fx.fromStoreId)
      final history = await db.stockTransferDao.watchHistoryForStore(fx.fromStoreId).first;

      // Should contain exactly t1 and t2 (received and cancelled involving Store A)
      expect(history.length, equals(2));
      final ids = history.map((e) => e.id).toList();
      expect(ids, contains(t1));
      expect(ids, contains(t2));
      expect(ids, isNot(contains(t3)));
      expect(ids, isNot(contains(t4)));
      expect(ids, isNot(contains(t5)));

      // Sorted newest first: t2 (initiated/cancelled later) should be before t1
      expect(history[0].id, equals(t2));
      expect(history[1].id, equals(t1));
    });
  });
}
