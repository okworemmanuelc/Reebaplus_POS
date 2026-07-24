// daily_closings_dao_test.dart
//
// The DAO/in-memory-Drift seam for the persisted day close (#174, PRD #155,
// ADR 0021 §2). The behaviour under test is the acceptance criterion:
//
//   * The FIRST review of a finished day writes exactly ONE daily_closings row
//     and enqueues it for sync.
//   * A re-open (this device or another) is FIRST-WRITER-WINS: the existing
//     snapshot is never overwritten, and no second push is enqueued.
//   * The id is DETERMINISTIC from (business_id, business_date) so two devices
//     converge on one row instead of racing two ids.
//
// Asserts the resulting rows + the enqueued payload at the public DAO surface —
// never internal call order.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

import '../helpers/dispatch_test_utils.dart';

DailyClosingFigures _figures({
  int totalSalesKobo = 500000,
  int netProfitKobo = 120000,
  int netCashMovementKobo = 300000,
  int stockExpectedClosingKobo = 900000,
  int itemsSold = 42,
}) => DailyClosingFigures(
      totalSalesKobo: totalSalesKobo,
      refundsKobo: 0,
      discountsKobo: 1000,
      cogsKobo: 200000,
      grossProfitKobo: 300000,
      netProfitKobo: netProfitKobo,
      expensesKobo: 50000,
      damagesCostKobo: 0,
      cashSalesKobo: 400000,
      cashInKobo: 450000,
      cashOutKobo: 150000,
      netCashMovementKobo: netCashMovementKobo,
      stockCogsKobo: 200000,
      stockExpectedClosingKobo: stockExpectedClosingKobo,
      itemsSold: itemsSold,
      shortageUnits: 0,
    );

void main() {
  test('first review writes exactly one snapshot row and enqueues it', () async {
    final boot = await bootstrapTestDb();
    try {
      final id = await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-20',
        storeScopeId: null,
        figures: _figures(),
      );

      // Exactly one row, carrying the frozen figures + the reviewed timestamp.
      final rows = await boot.db.select(boot.db.dailyClosings).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, id);
      expect(rows.single.businessDate, '2026-07-20');
      expect(rows.single.totalSalesKobo, 500000);
      expect(rows.single.netProfitKobo, 120000);
      expect(rows.single.itemsSold, 42);

      // Deterministic id from the natural key.
      expect(
        id,
        DailyClosingsDao.snapshotId(boot.businessId, '2026-07-20'),
      );

      // A daily_closings:upsert is enqueued carrying the full row (so peers
      // converge). The payload sets an explicit id + defaulted columns.
      final pending = await getPendingQueue(boot.db);
      final push = pending.singleWhere(
        (r) => r.actionType == 'daily_closings:upsert',
      );
      final payload = jsonDecode(push.payload) as Map<String, dynamic>;
      expect(payload['id'], id);
      expect(payload['business_id'], boot.businessId);
      expect(payload['business_date'], '2026-07-20');
      expect(payload['total_sales_kobo'], 500000);
      expect(payload['reviewed_at'], isNotNull);
      expect(payload['created_at'], isNotNull);
    } finally {
      await boot.db.close();
    }
  });

  test('re-opening the same day is first-writer-wins — no overwrite, no second '
      'push', () async {
    final boot = await bootstrapTestDb();
    try {
      final firstId = await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-20',
        storeScopeId: null,
        figures: _figures(totalSalesKobo: 500000, netProfitKobo: 120000),
      );

      // A later re-open recomputes DIFFERENT live figures (a late sync landed),
      // and tries to snapshot again. The natural key already has a winner.
      final secondId = await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-20',
        storeScopeId: null,
        figures: _figures(totalSalesKobo: 999999, netProfitKobo: 888888),
      );

      expect(secondId, firstId, reason: 'the natural key converges to one id');

      final rows = await boot.db.select(boot.db.dailyClosings).get();
      expect(rows, hasLength(1), reason: 'no second row on re-open');
      expect(rows.single.totalSalesKobo, 500000,
          reason: 'the AS-REVIEWED figure must not be overwritten');
      expect(rows.single.netProfitKobo, 120000);

      // The second call must not enqueue a fresh/competing push (it is a no-op).
      final pushes = (await getPendingQueue(boot.db))
          .where((r) => r.actionType == 'daily_closings:upsert')
          .toList();
      expect(pushes, hasLength(1),
          reason: 're-open enqueues nothing — one push only');
      final payload = jsonDecode(pushes.single.payload) as Map<String, dynamic>;
      expect(payload['total_sales_kobo'], 500000,
          reason: 'the enqueued payload stays the first-writer figures');
    } finally {
      await boot.db.close();
    }
  });

  test('distinct days each get their own snapshot row', () async {
    final boot = await bootstrapTestDb();
    try {
      await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-20',
        storeScopeId: null,
        figures: _figures(),
      );
      await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-21',
        storeScopeId: null,
        figures: _figures(totalSalesKobo: 111111),
      );

      final rows = await boot.db.select(boot.db.dailyClosings).get();
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.businessDate).toSet(),
        {'2026-07-20', '2026-07-21'},
      );

      final byDay = await boot.db.dailyClosingsDao.getForDay('2026-07-21');
      expect(byDay, isNotNull);
      expect(byDay!.totalSalesKobo, 111111);
    } finally {
      await boot.db.close();
    }
  });

  test('watchForDay emits the snapshot reactively, null before review',
      () async {
    final boot = await bootstrapTestDb();
    try {
      expect(await boot.db.dailyClosingsDao.watchForDay('2026-07-20').first,
          isNull);

      await boot.db.dailyClosingsDao.snapshotIfAbsent(
        businessDate: '2026-07-20',
        storeScopeId: null,
        figures: _figures(),
      );

      final snap =
          await boot.db.dailyClosingsDao.watchForDay('2026-07-20').first;
      expect(snap, isNotNull);
      expect(snap!.totalSalesKobo, 500000);
    } finally {
      await boot.db.close();
    }
  });
}
