import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

class _Seed {
  final String businessId;
  final String storeId;
  final String supplierId;

  _Seed({
    required this.businessId,
    required this.storeId,
    required this.supplierId,
  });
}

Future<_Seed> _seed(AppDatabase db, {String? businessIdInput}) async {
  final businessId = businessIdInput ?? UuidV7.generate();
  db.businessIdResolver = () => businessId;

  await db.into(db.businesses).insert(
    BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
  );

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
    StoresCompanion.insert(
      id: Value(storeId),
      businessId: businessId,
      name: 'Main Store',
    ),
  );

  await db.into(db.users).insert(
    UsersCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: businessId,
      name: 'CEO',
      pin: '000000',
    ),
  );

  final supplierId = await db.catalogDao.insertSupplier(
    SuppliersCompanion.insert(businessId: businessId, name: 'SAB'),
  );

  return _Seed(
    businessId: businessId,
    storeId: storeId,
    supplierId: supplierId,
  );
}

Future<String> _insertEntry(
  AppDatabase db,
  _Seed s, {
  required String id,
  required int signedAmountKobo,
  required String type,
  required String referenceType,
  required DateTime createdAt,
  required DateTime activityDate,
  String? storeId,
  String? businessId,
  DateTime? voidedAt,
}) async {
  await db.into(db.supplierLedgerEntries).insert(
    SupplierLedgerEntriesCompanion.insert(
      id: Value(id),
      businessId: businessId ?? s.businessId,
      supplierId: s.supplierId,
      storeId: Value(storeId ?? s.storeId),
      type: type,
      amountKobo: signedAmountKobo.abs(),
      signedAmountKobo: signedAmountKobo,
      referenceType: referenceType,
      activityDate: activityDate,
      createdAt: Value(createdAt),
      lastUpdatedAt: Value(createdAt),
      voidedAt: Value(voidedAt),
    ),
  );
  return id;
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('Supplier History Keyset Pagination Tests', () {
    // ── Test 1 — mixed-direction keyset boundary (critical) ──────────────────
    test('1. Mixed-direction keyset boundary (critical)', () async {
      final s = await _seed(db);

      // Three distinct seconds.
      final t1 = DateTime(2026, 6, 22, 12, 0, 0);
      final t2 = DateTime(2026, 6, 22, 12, 0, 1); // same-second boundary
      final t3 = DateTime(2026, 6, 22, 12, 0, 2);

      // t3 entries (newest — should appear first)
      await _insertEntry(db, s, id: 'e-1', signedAmountKobo: -5000, type: 'debit', referenceType: 'invoice', createdAt: t3, activityDate: t3);
      await _insertEntry(db, s, id: 'e-2', signedAmountKobo: 3000, type: 'credit', referenceType: 'payment_cash', createdAt: t3, activityDate: t3);

      // t2 entries — same second, DIFFERENT signedAmountKobo values
      // ASC by signedAmountKobo: -7000 < -2000 < 1000 < 4000
      // But ORDER is: created_at DESC, signedAmountKobo ASC, id DESC
      // Among t2: signedAmountKobo ASC gives: -7000, -2000, 1000, 4000
      // Two entries with same signedAmountKobo=-2000 → id DESC breaks tie
      await _insertEntry(db, s, id: 'e-a2', signedAmountKobo: -2000, type: 'debit', referenceType: 'invoice', createdAt: t2, activityDate: t2);
      await _insertEntry(db, s, id: 'e-b2', signedAmountKobo: -2000, type: 'debit', referenceType: 'invoice', createdAt: t2, activityDate: t2);
      await _insertEntry(db, s, id: 'e-c2', signedAmountKobo: -7000, type: 'debit', referenceType: 'invoice', createdAt: t2, activityDate: t2);
      await _insertEntry(db, s, id: 'e-d2', signedAmountKobo: 1000, type: 'credit', referenceType: 'payment_cash', createdAt: t2, activityDate: t2);
      await _insertEntry(db, s, id: 'e-e2', signedAmountKobo: 4000, type: 'credit', referenceType: 'payment_cash', createdAt: t2, activityDate: t2);

      // t1 entries (oldest)
      await _insertEntry(db, s, id: 'e-3', signedAmountKobo: 2000, type: 'credit', referenceType: 'payment_cash', createdAt: t1, activityDate: t1);

      // Page through with limit: 2 and collect all.
      final List<SupplierLedgerEntryData> allPages = [];
      ({DateTime createdAt, int signedAmountKobo, String id})? cursor;

      while (true) {
        final page = await db.supplierLedgerDao.getSupplierHistoryPage(
          cursor: cursor,
          limit: 2,
        );
        if (page.isEmpty) break;
        allPages.addAll(page);
        final last = page.last;
        cursor = (
          createdAt: last.createdAt,
          signedAmountKobo: last.signedAmountKobo,
          id: last.id,
        );
      }

      expect(allPages, hasLength(8));

      // Expected full order: created_at DESC, signedAmountKobo ASC, id DESC
      // t3 group: signedAmountKobo: -5000 (e-1), 3000 (e-2)
      // t2 group: signedAmountKobo ASC → -7000(e-c2), -2000 DESC id → (e-b2, e-a2), 1000(e-d2), 4000(e-e2)
      // t1 group: e-3
      expect(allPages[0].id, equals('e-1')); // t3: -5000
      expect(allPages[1].id, equals('e-2')); // t3: 3000
      expect(allPages[2].id, equals('e-c2')); // t2: -7000
      // e-b2 and e-a2 both have signedAmountKobo=-2000; id DESC: 'e-b2' > 'e-a2'
      expect(allPages[3].id, equals('e-b2')); // t2: -2000, id desc
      expect(allPages[4].id, equals('e-a2')); // t2: -2000
      expect(allPages[5].id, equals('e-d2')); // t2: 1000
      expect(allPages[6].id, equals('e-e2')); // t2: 4000
      expect(allPages[7].id, equals('e-3')); // t1: 2000

      // No duplicates.
      final ids = allPages.map((e) => e.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    // ── Test 2 — hasMore / partial last page / exact-multiple ──────────────
    test('2. hasMore / partial last page / exact-multiple', () async {
      final s = await _seed(db);
      final base = DateTime(2026, 6, 22, 12, 0, 0);

      // Insert 5 entries.
      for (int i = 1; i <= 5; i++) {
        await _insertEntry(
          db,
          s,
          id: 'e-$i',
          signedAmountKobo: i * 1000,
          type: 'credit',
          referenceType: 'payment_cash',
          createdAt: base.add(Duration(seconds: i)),
          activityDate: base.add(Duration(seconds: i)),
        );
      }

      // Page 1.
      final page1 = await db.supplierLedgerDao.getSupplierHistoryPage(limit: 2);
      expect(page1, hasLength(2));

      // Page 2.
      final last1 = page1.last;
      final page2 = await db.supplierLedgerDao.getSupplierHistoryPage(
        limit: 2,
        cursor: (
          createdAt: last1.createdAt,
          signedAmountKobo: last1.signedAmountKobo,
          id: last1.id,
        ),
      );
      expect(page2, hasLength(2));

      // Page 3 — partial last page.
      final last2 = page2.last;
      final page3 = await db.supplierLedgerDao.getSupplierHistoryPage(
        limit: 2,
        cursor: (
          createdAt: last2.createdAt,
          signedAmountKobo: last2.signedAmountKobo,
          id: last2.id,
        ),
      );
      expect(page3, hasLength(1));

      // Exact-multiple: 4 entries, limit 2 → third page is empty (no loop).
      final s2 = await _seed(db, businessIdInput: UuidV7.generate());
      for (int i = 1; i <= 4; i++) {
        await _insertEntry(
          db,
          s2,
          id: 'f-$i',
          signedAmountKobo: i * 500,
          type: 'credit',
          referenceType: 'payment_cash',
          createdAt: base.add(Duration(seconds: i)),
          activityDate: base.add(Duration(seconds: i)),
        );
      }
      final mp1 = await db.supplierLedgerDao.getSupplierHistoryPage(limit: 2);
      expect(mp1, hasLength(2));
      final ml1 = mp1.last;
      final mp2 = await db.supplierLedgerDao.getSupplierHistoryPage(
        limit: 2,
        cursor: (
          createdAt: ml1.createdAt,
          signedAmountKobo: ml1.signedAmountKobo,
          id: ml1.id,
        ),
      );
      expect(mp2, hasLength(2));
      final ml2 = mp2.last;
      final mp3 = await db.supplierLedgerDao.getSupplierHistoryPage(
        limit: 2,
        cursor: (
          createdAt: ml2.createdAt,
          signedAmountKobo: ml2.signedAmountKobo,
          id: ml2.id,
        ),
      );
      expect(mp3, isEmpty); // no infinite loop
    });

    // ── Test 3 — date push-down on activityDate, not createdAt ───────────────
    test('3. Date push-down uses activityDate (not createdAt)', () async {
      final s = await _seed(db);

      final cutoff = DateTime(2026, 6, 15);

      // Row A: activityDate on/after cutoff, createdAt before cutoff → INCLUDED.
      await _insertEntry(
        db,
        s,
        id: 'row-A',
        signedAmountKobo: 1000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: DateTime(2026, 6, 10), // before cutoff
        activityDate: DateTime(2026, 6, 16), // after cutoff → included
      );

      // Row B: activityDate before cutoff, createdAt on/after cutoff → EXCLUDED.
      await _insertEntry(
        db,
        s,
        id: 'row-B',
        signedAmountKobo: -2000,
        type: 'debit',
        referenceType: 'invoice',
        createdAt: DateTime(2026, 6, 20), // after cutoff
        activityDate: DateTime(2026, 6, 14), // before cutoff → excluded
      );

      // Row C: activityDate exactly on cutoff → INCLUDED.
      await _insertEntry(
        db,
        s,
        id: 'row-C',
        signedAmountKobo: 500,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: DateTime(2026, 6, 20),
        activityDate: cutoff,
      );

      final result = await db.supplierLedgerDao.getSupplierHistoryPage(
        startDate: cutoff,
      );

      final ids = result.map((e) => e.id).toSet();
      expect(ids.contains('row-A'), isTrue); // activityDate after cutoff
      expect(ids.contains('row-C'), isTrue); // activityDate == cutoff
      expect(ids.contains('row-B'), isFalse); // activityDate before cutoff
    });

    // ── Test 4 — store scope + business scope ─────────────────────────────────
    test('4. Store scope and business scope', () async {
      final biz1Id = UuidV7.generate();
      final s1 = await _seed(db, businessIdInput: biz1Id);

      final otherStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(otherStoreId),
          businessId: biz1Id,
          name: 'Other Store',
        ),
      );

      final biz2Id = UuidV7.generate();
      db.businessIdResolver = () => biz2Id;
      final s2 = await _seed(db, businessIdInput: biz2Id);

      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // s1 store
      await _insertEntry(
        db,
        s1,
        id: 'e-s1',
        signedAmountKobo: 1000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: t,
        activityDate: t,
        storeId: s1.storeId,
        businessId: biz1Id,
      );
      // other store under biz1
      await _insertEntry(
        db,
        s1,
        id: 'e-other',
        signedAmountKobo: 2000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: t,
        activityDate: t,
        storeId: otherStoreId,
        businessId: biz1Id,
      );
      // s2 (different business)
      await _insertEntry(
        db,
        s2,
        id: 'e-s2',
        signedAmountKobo: 3000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: t,
        activityDate: t,
        businessId: biz2Id,
      );

      // Under biz1, store-scoped to s1.storeId — only e-s1.
      db.businessIdResolver = () => biz1Id;
      final biz1StoreResult = await db.supplierLedgerDao
          .getSupplierHistoryPage(storeId: s1.storeId);
      expect(biz1StoreResult.map((e) => e.id).toList(), equals(['e-s1']));

      // Under biz1, no store filter — biz1 entries only (e-s1 + e-other).
      final biz1AllResult =
          await db.supplierLedgerDao.getSupplierHistoryPage();
      final biz1Ids = biz1AllResult.map((e) => e.id).toSet();
      expect(biz1Ids, containsAll(['e-s1', 'e-other']));
      expect(biz1Ids.contains('e-s2'), isFalse);

      // Under biz2 — only e-s2.
      db.businessIdResolver = () => biz2Id;
      final biz2Result = await db.supplierLedgerDao.getSupplierHistoryPage();
      expect(biz2Result.map((e) => e.id).toList(), equals(['e-s2']));
    });

    // ── Test 5 — voided + void rows appear in list ───────────────────────────
    test('5. Voided and void rows are INCLUDED in the page list', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // A normal row.
      await _insertEntry(
        db,
        s,
        id: 'e-normal',
        signedAmountKobo: 1000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: t,
        activityDate: t,
      );
      // A row that has been voided (voidedAt is set).
      await _insertEntry(
        db,
        s,
        id: 'e-voided-original',
        signedAmountKobo: -5000,
        type: 'debit',
        referenceType: 'invoice',
        createdAt: t.add(const Duration(seconds: 1)),
        activityDate: t.add(const Duration(seconds: 1)),
        voidedAt: DateTime(2026, 6, 22, 12, 1, 0),
      );
      // A compensating void row (referenceType='void').
      await _insertEntry(
        db,
        s,
        id: 'e-void-comp',
        signedAmountKobo: 5000,
        type: 'credit',
        referenceType: 'void',
        createdAt: t.add(const Duration(seconds: 2)),
        activityDate: t.add(const Duration(seconds: 2)),
      );

      final result =
          await db.supplierLedgerDao.getSupplierHistoryPage();
      final ids = result.map((e) => e.id).toSet();

      // All three rows must appear (Trap 2 — no voidedAt filter on the list).
      expect(ids.contains('e-normal'), isTrue);
      expect(ids.contains('e-voided-original'), isTrue);
      expect(ids.contains('e-void-comp'), isTrue);
      expect(result, hasLength(3));
    });

    // ── Test 6 — stats semantics ──────────────────────────────────────────────
    test('6. Stats semantics: count includes voided/void; totals exclude them; NULL-safe', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // Normal credit (payment): counted in totalIn.
      await _insertEntry(
        db,
        s,
        id: 'e-normal-in',
        signedAmountKobo: 3000,
        type: 'credit',
        referenceType: 'payment_cash',
        createdAt: t,
        activityDate: t,
      );
      // Normal debit (invoice): counted in totalOut.
      await _insertEntry(
        db,
        s,
        id: 'e-normal-out',
        signedAmountKobo: -7000,
        type: 'debit',
        referenceType: 'invoice',
        createdAt: t.add(const Duration(seconds: 1)),
        activityDate: t.add(const Duration(seconds: 1)),
      );
      // Voided original (voidedAt set): in count but NOT in totalOut.
      await _insertEntry(
        db,
        s,
        id: 'e-voided',
        signedAmountKobo: -4000,
        type: 'debit',
        referenceType: 'invoice',
        createdAt: t.add(const Duration(seconds: 2)),
        activityDate: t.add(const Duration(seconds: 2)),
        voidedAt: DateTime(2026, 6, 22, 12, 1, 0),
      );
      // Void compensating row (referenceType='void'): in count but NOT in totalIn.
      await _insertEntry(
        db,
        s,
        id: 'e-void-comp',
        signedAmountKobo: 4000,
        type: 'credit',
        referenceType: 'void',
        createdAt: t.add(const Duration(seconds: 3)),
        activityDate: t.add(const Duration(seconds: 3)),
      );
      // Row with non-void referenceType (not null) — verify it's included normally.
      // This tests that only referenceType='void' is excluded, not all non-null.
      await _insertEntry(
        db,
        s,
        id: 'e-order-payment',
        signedAmountKobo: 1000,
        type: 'credit',
        referenceType: 'payment_pos',
        createdAt: t.add(const Duration(seconds: 4)),
        activityDate: t.add(const Duration(seconds: 4)),
      );

      final stats =
          await db.supplierLedgerDao.watchSupplierHistoryStats().first;

      // count = ALL 5 rows (voided original + void comp included).
      expect(stats.count, equals(5));
      // totalIn = non-voided, non-void-comp credits only: 3000 + 1000 = 4000.
      expect(stats.totalIn, equals(4000));
      // totalOut = non-voided debits only: 7000.
      expect(stats.totalOut, equals(7000));

      // Paging must not affect stats.
      final page1 = await db.supplierLedgerDao.getSupplierHistoryPage(limit: 2);
      expect(page1, hasLength(2));
      final statsAfterPage =
          await db.supplierLedgerDao.watchSupplierHistoryStats().first;
      expect(statsAfterPage.count, equals(5));
      expect(statsAfterPage.totalIn, equals(4000));
      expect(statsAfterPage.totalOut, equals(7000));
    });
  });
}
