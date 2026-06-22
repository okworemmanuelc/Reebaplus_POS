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

  _Seed({
    required this.businessId,
    required this.storeId,
    required this.staffId,
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

  return _Seed(
    businessId: businessId,
    storeId: storeId,
    staffId: staffId,
  );
}

Future<void> _insertActivityLog(
  AppDatabase db,
  _Seed s, {
  required String id,
  required String action,
  required String description,
  required DateTime createdAt,
  String? storeId,
  String? entityType,
  String? entityId,
  DateTime? voidedAt,
  String? businessId,
}) async {
  await db.into(db.activityLogs).insert(
        ActivityLogsCompanion.insert(
          id: Value(id),
          businessId: businessId ?? s.businessId,
          userId: Value(s.staffId),
          action: action,
          description: description,
          createdAt: Value(createdAt),
          storeId: Value(storeId),
          entityType: Value(entityType),
          entityId: Value(entityId),
          voidedAt: Value(voidedAt),
          lastUpdatedAt: Value(createdAt),
        ),
      );
}

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('Activity Logs Pagination Tests', () {
    test('1. Same-second boundary (critical case)', () async {
      final s = await _seed(db);

      // Create 9 activity logs.
      // identical second boundary has 5 logs: log-3, log-4, log-5, log-6, log-7
      final t1 = DateTime(2026, 6, 22, 12, 0, 0);
      final t2 = DateTime(2026, 6, 22, 12, 0, 1);
      final t3 = DateTime(2026, 6, 22, 12, 0, 2);

      await _insertActivityLog(db, s, id: 'log-1', action: 'Generic Action', description: 'Log 1', createdAt: t1);
      await _insertActivityLog(db, s, id: 'log-2', action: 'Generic Action', description: 'Log 2', createdAt: t1);

      await _insertActivityLog(db, s, id: 'log-3', action: 'Generic Action', description: 'Log 3', createdAt: t2);
      await _insertActivityLog(db, s, id: 'log-4', action: 'Generic Action', description: 'Log 4', createdAt: t2);
      await _insertActivityLog(db, s, id: 'log-5', action: 'Generic Action', description: 'Log 5', createdAt: t2);
      await _insertActivityLog(db, s, id: 'log-6', action: 'Generic Action', description: 'Log 6', createdAt: t2);
      await _insertActivityLog(db, s, id: 'log-7', action: 'Generic Action', description: 'Log 7', createdAt: t2);

      await _insertActivityLog(db, s, id: 'log-8', action: 'Generic Action', description: 'Log 8', createdAt: t3);
      await _insertActivityLog(db, s, id: 'log-9', action: 'Generic Action', description: 'Log 9', createdAt: t3);

      // Page through with limit: 2
      final List<ActivityLogData> allPages = [];
      ({DateTime createdAt, String id})? cursor;

      while (true) {
        final page = await db.activityLogDao.getActivityLogsPage(
          cursor: cursor,
          limit: 2,
        );
        if (page.isEmpty) break;
        allPages.addAll(page);
        final last = page.last;
        cursor = (createdAt: last.createdAt, id: last.id);
      }

      // Assert global order is created_at DESC, id DESC
      expect(allPages, hasLength(9));
      expect(allPages[0].id, equals('log-9'));
      expect(allPages[1].id, equals('log-8'));
      expect(allPages[2].id, equals('log-7'));
      expect(allPages[3].id, equals('log-6'));
      expect(allPages[4].id, equals('log-5'));
      expect(allPages[5].id, equals('log-4'));
      expect(allPages[6].id, equals('log-3'));
      expect(allPages[7].id, equals('log-2'));
      expect(allPages[8].id, equals('log-1'));
    });

    test('2. Page size / hasMore semantics - Scenario A: partial last page', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      for (int i = 1; i <= 5; i++) {
        await _insertActivityLog(
          db,
          s,
          id: 'log-$i',
          action: 'Action',
          description: 'Desc $i',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final page1 = await db.activityLogDao.getActivityLogsPage(limit: 2);
      expect(page1, hasLength(2));
      final last1 = page1.last;

      final page2 = await db.activityLogDao.getActivityLogsPage(
        limit: 2,
        cursor: (createdAt: last1.createdAt, id: last1.id),
      );
      expect(page2, hasLength(2));
      final last2 = page2.last;

      final page3 = await db.activityLogDao.getActivityLogsPage(
        limit: 2,
        cursor: (createdAt: last2.createdAt, id: last2.id),
      );
      expect(page3, hasLength(1)); // Partial last page!
    });

    test('3. Page size / hasMore semantics - Scenario B: exact-multiple count', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      for (int i = 1; i <= 4; i++) {
        await _insertActivityLog(
          db,
          s,
          id: 'log-$i',
          action: 'Action',
          description: 'Desc $i',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final mPage1 = await db.activityLogDao.getActivityLogsPage(limit: 2);
      expect(mPage1, hasLength(2));
      final mLast1 = mPage1.last;

      final mPage2 = await db.activityLogDao.getActivityLogsPage(
        limit: 2,
        cursor: (createdAt: mLast1.createdAt, id: mLast1.id),
      );
      expect(mPage2, hasLength(2));
      final mLast2 = mPage2.last;

      final mPage3 = await db.activityLogDao.getActivityLogsPage(
        limit: 2,
        cursor: (createdAt: mLast2.createdAt, id: mLast2.id),
      );
      expect(mPage3, isEmpty); // Returns empty, no infinite loop
    });

    test('4. Store-filter heuristic push-down', () async {
      final s = await _seed(db);

      // Create a custom store
      final otherStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(otherStoreId),
              businessId: s.businessId,
              name: 'Other Store',
            ),
          );

      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // A: Global log (storeId null, non-store-scoped action/entity)
      // Should appear under All Stores (null) and under specific stores because isStoreScoped is false
      await _insertActivityLog(
        db,
        s,
        id: 'log-global',
        action: 'User Login',
        description: 'User logged in',
        createdAt: t,
      );

      // B: Store-scoped by storeId
      await _insertActivityLog(
        db,
        s,
        id: 'log-store1',
        action: 'Some Action',
        description: 'Store 1 action',
        createdAt: t,
        storeId: s.storeId,
      );

      // C: Store-scoped by entityType
      await _insertActivityLog(
        db,
        s,
        id: 'log-product',
        action: 'Update Product',
        description: 'Product updated',
        createdAt: t,
        entityType: 'product',
        storeId: otherStoreId, // scoped to other store
      );

      // D: Store-scoped by action keyword ('stock')
      await _insertActivityLog(
        db,
        s,
        id: 'log-stock',
        action: 'Stock Count Done',
        description: 'Stock counted',
        createdAt: t,
        storeId: otherStoreId,
      );

      // 1. All Stores (storeId = null) returns everything
      final allLogs = await db.activityLogDao.getActivityLogsPage(storeId: null);
      expect(allLogs, hasLength(4));

      // 2. Query for main store (s.storeId)
      // Should return 'log-global' (non-store-scoped) and 'log-store1' (storeId matches)
      final mainStoreLogs = await db.activityLogDao.getActivityLogsPage(storeId: s.storeId);
      expect(mainStoreLogs, hasLength(2));
      final mainIds = mainStoreLogs.map((l) => l.id).toSet();
      expect(mainIds, contains('log-global'));
      expect(mainIds, contains('log-store1'));

      // 3. Query for other store
      // Should return 'log-global' (non-store-scoped), 'log-product' (storeId matches), 'log-stock' (storeId matches)
      final otherStoreLogs = await db.activityLogDao.getActivityLogsPage(storeId: otherStoreId);
      expect(otherStoreLogs, hasLength(3));
      final otherIds = otherStoreLogs.map((l) => l.id).toSet();
      expect(otherIds, contains('log-global'));
      expect(otherIds, contains('log-product'));
      expect(otherIds, contains('log-stock'));
    });

    test('5. Business scoping', () async {
      final bizId1 = UuidV7.generate();
      final s1 = await _seed(db, businessIdInput: bizId1);

      final bizId2 = UuidV7.generate();
      db.businessIdResolver = () => bizId2;
      final s2 = await _seed(db, businessIdInput: bizId2);

      final t = DateTime(2026, 6, 22, 12, 0, 0);

      await _insertActivityLog(db, s1, id: 'log-biz1', action: 'Act', description: 'B1', createdAt: t, businessId: bizId1);
      await _insertActivityLog(db, s2, id: 'log-biz2', action: 'Act', description: 'B2', createdAt: t, businessId: bizId2);

      // Query under business 1
      db.businessIdResolver = () => bizId1;
      final results1 = await db.activityLogDao.getActivityLogsPage();
      expect(results1, hasLength(1));
      expect(results1.first.id, equals('log-biz1'));

      // Query under business 2
      db.businessIdResolver = () => bizId2;
      final results2 = await db.activityLogDao.getActivityLogsPage();
      expect(results2, hasLength(1));
      expect(results2.first.id, equals('log-biz2'));
    });

    test('6. Void exclusion', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      await _insertActivityLog(db, s, id: 'log-active', action: 'Act', description: 'Active', createdAt: t);
      await _insertActivityLog(db, s, id: 'log-voided', action: 'Act', description: 'Voided', createdAt: t, voidedAt: DateTime.now());

      final results = await db.activityLogDao.getActivityLogsPage();
      expect(results, hasLength(1));
      expect(results.first.id, equals('log-active'));
    });

    group('watchActivityLogsPage', () {
      test('Streams live head', () async {
        final s = await _seed(db);
        final t = DateTime(2026, 6, 22, 12, 0, 0);

        await _insertActivityLog(db, s, id: 'log-1', action: 'A', description: '1', createdAt: t);
        await _insertActivityLog(db, s, id: 'log-2', action: 'A', description: '2', createdAt: t.add(const Duration(seconds: 1)));
        await _insertActivityLog(db, s, id: 'log-3', action: 'A', description: '3', createdAt: t.add(const Duration(seconds: 2)));

        final list = await db.activityLogDao.watchActivityLogsPage(limit: 2).first;
        expect(list, hasLength(2));
        expect(list[0].id, equals('log-3'));
        expect(list[1].id, equals('log-2'));
      });
    });
  });
}
