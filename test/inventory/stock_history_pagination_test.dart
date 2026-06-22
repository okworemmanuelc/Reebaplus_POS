import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

class _Seed {
  final String businessId;
  final String storeId;
  final String staffId;
  final String productId;

  _Seed({
    required this.businessId,
    required this.storeId,
    required this.staffId,
    required this.productId,
  });
}

Future<_Seed> _seed(
  AppDatabase db, {
  String? businessIdInput,
  String timezone = 'Africa/Lagos',
}) async {
  final businessId = businessIdInput ?? UuidV7.generate();
  db.businessIdResolver = () => businessId;

  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
          timezone: Value(timezone),
        ),
      );

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ),
      );

  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Staff A',
          pin: '0000',
        ),
      );

  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Product A',
          retailerPriceKobo: const Value(500),
        ),
      );

  return _Seed(
    businessId: businessId,
    storeId: storeId,
    staffId: staffId,
    productId: productId,
  );
}

Future<void> _insertStockTransaction(
  AppDatabase db,
  _Seed s, {
  required String id,
  required String productId,
  required int quantityDelta,
  required String movementType,
  required DateTime createdAt,
  String? storeId,
  String? orderId,
  String? adjustmentId,
  DateTime? voidedAt,
  String? businessId,
}) async {
  final String actualAdjustmentId = adjustmentId ?? UuidV7.generate();

  if (orderId == null && adjustmentId == null) {
    await db.into(db.stockAdjustments).insert(
          StockAdjustmentsCompanion.insert(
            id: Value(actualAdjustmentId),
            businessId: businessId ?? s.businessId,
            productId: productId,
            storeId: storeId ?? s.storeId,
            quantityDiff: quantityDelta,
            reason: 'Test adjustment',
            performedBy: Value(s.staffId),
            createdAt: Value(createdAt),
            lastUpdatedAt: Value(createdAt),
          ),
        );
  }

  await db.into(db.stockTransactions).insert(
        StockTransactionsCompanion.insert(
          id: Value(id),
          businessId: businessId ?? s.businessId,
          productId: productId,
          locationId: storeId ?? s.storeId,
          quantityDelta: quantityDelta,
          movementType: movementType,
          orderId: Value(orderId),
          adjustmentId: Value(orderId == null ? actualAdjustmentId : null),
          performedBy: Value(s.staffId),
          createdAt: Value(createdAt),
          lastUpdatedAt: Value(createdAt),
          voidedAt: Value(voidedAt),
        ),
      );
}

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('Stock History Keyset Pagination Tests', () {
    test('1. Same-second boundary (critical case)', () async {
      final s = await _seed(db);

      // Create 9 transactions.
      // Identical second boundary has 5 transactions: tx-3, tx-4, tx-5, tx-6, tx-7
      final t1 = DateTime(2026, 6, 22, 12, 0, 0);
      final t2 = DateTime(2026, 6, 22, 12, 0, 1);
      final t3 = DateTime(2026, 6, 22, 12, 0, 2);

      await _insertStockTransaction(db, s, id: 'tx-1', productId: s.productId, quantityDelta: 5, movementType: 'purchase_received', createdAt: t1);
      await _insertStockTransaction(db, s, id: 'tx-2', productId: s.productId, quantityDelta: -2, movementType: 'sale', createdAt: t1);

      await _insertStockTransaction(db, s, id: 'tx-3', productId: s.productId, quantityDelta: 3, movementType: 'purchase_received', createdAt: t2);
      await _insertStockTransaction(db, s, id: 'tx-4', productId: s.productId, quantityDelta: -1, movementType: 'sale', createdAt: t2);
      await _insertStockTransaction(db, s, id: 'tx-5', productId: s.productId, quantityDelta: 4, movementType: 'purchase_received', createdAt: t2);
      await _insertStockTransaction(db, s, id: 'tx-6', productId: s.productId, quantityDelta: -3, movementType: 'sale', createdAt: t2);
      await _insertStockTransaction(db, s, id: 'tx-7', productId: s.productId, quantityDelta: 2, movementType: 'purchase_received', createdAt: t2);

      await _insertStockTransaction(db, s, id: 'tx-8', productId: s.productId, quantityDelta: -4, movementType: 'sale', createdAt: t3);
      await _insertStockTransaction(db, s, id: 'tx-9', productId: s.productId, quantityDelta: 1, movementType: 'purchase_received', createdAt: t3);

      // Page through with limit: 2
      final List<StockTransactionWithDetails> allPages = [];
      ({DateTime createdAt, String id})? cursor;

      while (true) {
        final page = await db.stockLedgerDao.getTransactionsPage(
          cursor: cursor,
          limit: 2,
        );
        if (page.isEmpty) break;
        allPages.addAll(page);
        final last = page.last;
        cursor = (createdAt: last.createdAt, id: last.transactionId);
      }

      // Assert global order is created_at DESC, id DESC
      expect(allPages, hasLength(9));
      expect(allPages[0].transactionId, equals('tx-9'));
      expect(allPages[1].transactionId, equals('tx-8'));
      expect(allPages[2].transactionId, equals('tx-7'));
      expect(allPages[3].transactionId, equals('tx-6'));
      expect(allPages[4].transactionId, equals('tx-5'));
      expect(allPages[5].transactionId, equals('tx-4'));
      expect(allPages[6].transactionId, equals('tx-3'));
      expect(allPages[7].transactionId, equals('tx-2'));
      expect(allPages[8].transactionId, equals('tx-1'));
    });

    test('2. hasMore / partial last page / exact-multiple', () async {
      final sA = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // Scenario A: partial last page (5 transactions, limit 2)
      for (int i = 1; i <= 5; i++) {
        await _insertStockTransaction(
          db,
          sA,
          id: 'tx-A-$i',
          productId: sA.productId,
          quantityDelta: i,
          movementType: 'purchase_received',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final page1 = await db.stockLedgerDao.getTransactionsPage(limit: 2);
      expect(page1, hasLength(2));
      final last1 = page1.last;

      final page2 = await db.stockLedgerDao.getTransactionsPage(
        limit: 2,
        cursor: (createdAt: last1.createdAt, id: last1.transactionId),
      );
      expect(page2, hasLength(2));
      final last2 = page2.last;

      final page3 = await db.stockLedgerDao.getTransactionsPage(
        limit: 2,
        cursor: (createdAt: last2.createdAt, id: last2.transactionId),
      );
      expect(page3, hasLength(1)); // Partial last page!

      // Scenario B: exact-multiple count (4 transactions, limit 2)
      // Use a new business seed to avoid deletion
      final bizIdB = UuidV7.generate();
      db.businessIdResolver = () => bizIdB;
      final sB = await _seed(db, businessIdInput: bizIdB);

      for (int i = 1; i <= 4; i++) {
        await _insertStockTransaction(
          db,
          sB,
          id: 'tx-B-$i',
          productId: sB.productId,
          quantityDelta: i,
          movementType: 'purchase_received',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final mPage1 = await db.stockLedgerDao.getTransactionsPage(limit: 2);
      expect(mPage1, hasLength(2));
      final mLast1 = mPage1.last;

      final mPage2 = await db.stockLedgerDao.getTransactionsPage(
        limit: 2,
        cursor: (createdAt: mLast1.createdAt, id: mLast1.transactionId),
      );
      expect(mPage2, hasLength(2));
      final mLast2 = mPage2.last;

      final mPage3 = await db.stockLedgerDao.getTransactionsPage(
        limit: 2,
        cursor: (createdAt: mLast2.createdAt, id: mLast2.transactionId),
      );
      expect(mPage3, isEmpty); // Returns empty, no infinite loop
    });

    test('3. Filter push-down', () async {
      final s = await _seed(db);

      // Create a second store
      final otherStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(otherStoreId),
              businessId: s.businessId,
              name: 'Other Store',
            ),
          );

      final t1 = DateTime(2026, 6, 20, 10, 0, 0);
      final t2 = DateTime(2026, 6, 21, 10, 0, 0);

      await _insertStockTransaction(
        db,
        s,
        id: 'tx-a',
        productId: s.productId,
        quantityDelta: 10,
        movementType: 'purchase_received',
        createdAt: t2,
        storeId: s.storeId,
      );
      await _insertStockTransaction(
        db,
        s,
        id: 'tx-b',
        productId: s.productId,
        quantityDelta: -5,
        movementType: 'sale',
        createdAt: t2,
        storeId: otherStoreId,
      );
      await _insertStockTransaction(
        db,
        s,
        id: 'tx-c',
        productId: s.productId,
        quantityDelta: 2,
        movementType: 'adjustment',
        createdAt: t1,
        storeId: s.storeId,
      );

      // A. Store Filter
      final store1Page = await db.stockLedgerDao.getTransactionsPage(storeId: s.storeId);
      expect(store1Page, hasLength(2));
      expect(store1Page.any((tx) => tx.transactionId == 'tx-b'), isFalse);

      // B. Date range filter
      final dateFiltered = await db.stockLedgerDao.getTransactionsPage(
        startDate: DateTime(2026, 6, 21, 0, 0, 0),
        endDate: DateTime(2026, 6, 21, 23, 59, 59),
      );
      expect(dateFiltered, hasLength(2));
      expect(dateFiltered.any((tx) => tx.transactionId == 'tx-c'), isFalse);

      // C. MovementType filter
      final salePage = await db.stockLedgerDao.getTransactionsPage(movementType: 'sale');
      expect(salePage, hasLength(1));
      expect(salePage.first.transactionId, equals('tx-b'));
    });

    test('4. Business scoping', () async {
      final bizId1 = UuidV7.generate();
      final s1 = await _seed(db, businessIdInput: bizId1);

      final bizId2 = UuidV7.generate();
      db.businessIdResolver = () => bizId2;
      final s2 = await _seed(db, businessIdInput: bizId2);

      final t = DateTime(2026, 6, 22, 12, 0, 0);

      await _insertStockTransaction(db, s1, id: 'tx-biz1', productId: s1.productId, quantityDelta: 5, movementType: 'purchase_received', createdAt: t, businessId: bizId1);
      await _insertStockTransaction(db, s2, id: 'tx-biz2', productId: s2.productId, quantityDelta: 10, movementType: 'purchase_received', createdAt: t, businessId: bizId2);

      // Query under business 1
      db.businessIdResolver = () => bizId1;
      final results1 = await db.stockLedgerDao.getTransactionsPage();
      expect(results1, hasLength(1));
      expect(results1.first.transactionId, equals('tx-biz1'));

      // Query under business 2
      db.businessIdResolver = () => bizId2;
      final results2 = await db.stockLedgerDao.getTransactionsPage();
      expect(results2, hasLength(1));
      expect(results2.first.transactionId, equals('tx-biz2'));
    });

    test('5. Void exclusion', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      await _insertStockTransaction(db, s, id: 'tx-active', productId: s.productId, quantityDelta: 5, movementType: 'purchase_received', createdAt: t);
      await _insertStockTransaction(db, s, id: 'tx-voided', productId: s.productId, quantityDelta: 10, movementType: 'purchase_received', createdAt: t, voidedAt: DateTime.now());

      final results = await db.stockLedgerDao.getTransactionsPage();
      expect(results, hasLength(1));
      expect(results.first.transactionId, equals('tx-active'));

      final stats = await db.stockLedgerDao.watchTransactionsStats().first;
      expect(stats.count, equals(1));
      expect(stats.totalIn, equals(5));
    });

    test('6. Stats aggregate over the FULL set', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // Seed 6 transactions (3 in, 3 out)
      await _insertStockTransaction(db, s, id: 'tx-1', productId: s.productId, quantityDelta: 5, movementType: 'purchase_received', createdAt: t);
      await _insertStockTransaction(db, s, id: 'tx-2', productId: s.productId, quantityDelta: 10, movementType: 'purchase_received', createdAt: t.add(const Duration(seconds: 1)));
      await _insertStockTransaction(db, s, id: 'tx-3', productId: s.productId, quantityDelta: 15, movementType: 'purchase_received', createdAt: t.add(const Duration(seconds: 2)));
      await _insertStockTransaction(db, s, id: 'tx-4', productId: s.productId, quantityDelta: -3, movementType: 'sale', createdAt: t.add(const Duration(seconds: 3)));
      await _insertStockTransaction(db, s, id: 'tx-5', productId: s.productId, quantityDelta: -7, movementType: 'sale', createdAt: t.add(const Duration(seconds: 4)));
      await _insertStockTransaction(db, s, id: 'tx-6', productId: s.productId, quantityDelta: -10, movementType: 'sale', createdAt: t.add(const Duration(seconds: 5)));

      // Query stats
      final stats = await db.stockLedgerDao.watchTransactionsStats().first;
      expect(stats.count, equals(6));
      expect(stats.totalIn, equals(30)); // 5 + 10 + 15
      expect(stats.totalOut, equals(20)); // |-3| + |-7| + |-10|

      // Page with limit: 2
      final page1 = await db.stockLedgerDao.getTransactionsPage(limit: 2);
      expect(page1, hasLength(2));

      // Stats should not change when page is requested
      final statsAfterPaging = await db.stockLedgerDao.watchTransactionsStats().first;
      expect(statsAfterPaging.count, equals(6));
      expect(statsAfterPaging.totalIn, equals(30));
      expect(statsAfterPaging.totalOut, equals(20));
    });

    group('watchTransactionsPage', () {
      test('Streams live head', () async {
        final s = await _seed(db);
        final t = DateTime(2026, 6, 22, 12, 0, 0);

        await _insertStockTransaction(db, s, id: 'tx-1', productId: s.productId, quantityDelta: 5, movementType: 'purchase_received', createdAt: t);
        await _insertStockTransaction(db, s, id: 'tx-2', productId: s.productId, quantityDelta: -2, movementType: 'sale', createdAt: t.add(const Duration(seconds: 1)));
        await _insertStockTransaction(db, s, id: 'tx-3', productId: s.productId, quantityDelta: 3, movementType: 'purchase_received', createdAt: t.add(const Duration(seconds: 2)));

        final list = await db.stockLedgerDao.watchTransactionsPage(limit: 2).first;
        expect(list, hasLength(2));
        expect(list[0].transactionId, equals('tx-3'));
        expect(list[1].transactionId, equals('tx-2'));
      });
    });
  });
}
