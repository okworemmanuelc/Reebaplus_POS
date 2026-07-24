// daily_closings_sync_test.dart
//
// The Cloud-Transport-fake seam for the persisted day close (#174, PRD #155,
// ADR 0021 §2). Proves the snapshot row makes the full round-trip across
// devices through the real sync engine and the in-memory transport:
//
//   1. PUSH — a snapshot written by the DAO drains through
//      `SupabaseSyncService.pushPending` and lands in the transport's
//      daily_closings store (peers can pull it).
//   2. PULL — a snake_case cloud row restores into local Drift via
//      `_restoreTableData` and surfaces through `DailyClosingsDao.watchForDay`.
//   3. FIRST-WRITER-WINS on the pull side — a divergent cloud snapshot for a day
//      this device already knows is IGNORED (insertOrIgnore), even with a newer
//      last_updated_at, so the as-reviewed figures never get clobbered.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

DailyClosingFigures _figures({int totalSalesKobo = 500000}) =>
    DailyClosingFigures(
      totalSalesKobo: totalSalesKobo,
      refundsKobo: 0,
      discountsKobo: 1000,
      cogsKobo: 200000,
      grossProfitKobo: 300000,
      netProfitKobo: 120000,
      expensesKobo: 50000,
      damagesCostKobo: 0,
      cashSalesKobo: 400000,
      cashInKobo: 450000,
      cashOutKobo: 150000,
      netCashMovementKobo: 300000,
      stockCogsKobo: 200000,
      stockExpectedClosingKobo: 900000,
      itemsSold: 42,
      shortageUnits: 0,
    );

void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'user-1');
    sync = SupabaseSyncService(db, transport);
  });

  tearDown(() async {
    await transport.dispose();
    await db.close();
  });

  test('a snapshot enqueues and pushes to the cloud through the transport',
      () async {
    final id = await db.dailyClosingsDao.snapshotIfAbsent(
      businessDate: '2026-07-20',
      storeScopeId: null,
      figures: _figures(),
    );

    // Drain the outbox to the transport exactly as pushPending does at the
    // transport boundary: one upsert per pending `daily_closings:upsert` payload
    // (daily_closings is a pass-through push table — no column scrub).
    final pending = (await getPendingQueue(db))
        .where((r) => r.actionType == 'daily_closings:upsert')
        .toList();
    expect(pending, hasLength(1), reason: 'the DAO enqueues one push');
    for (final row in pending) {
      await transport.upsertRows('daily_closings', [decodePayload(row)]);
    }

    // The row crossed the wire and is visible to a peer's later fetch.
    final pushed = transport.upsertedRows('daily_closings');
    expect(pushed, hasLength(1), reason: 'the snapshot must cross the wire');
    expect(pushed.single['id'], id);
    expect(pushed.single['business_id'], businessId);
    expect(pushed.single['business_date'], '2026-07-20');
    expect(pushed.single['total_sales_kobo'], 500000);

    final fetched = await transport.fetchTable(
      TableQuery('daily_closings', businessId, null, pageSize: 500),
    );
    expect(fetched.map((r) => r['id']), [id]);
  });

  test('a cloud snapshot restores locally and surfaces via watchForDay',
      () async {
    final id = DailyClosingsDao.snapshotId(businessId, '2026-07-20');
    final ts = DateTime.utc(2026, 7, 21, 8).toIso8601String();

    await sync.restoreTableDataForTesting('daily_closings', [
      {
        'id': id,
        'business_id': businessId,
        'business_date': '2026-07-20',
        'store_scope_id': null,
        'total_sales_kobo': 777000,
        'refunds_kobo': 0,
        'discounts_kobo': 0,
        'cogs_kobo': 0,
        'gross_profit_kobo': 0,
        'net_profit_kobo': 90000,
        'expenses_kobo': 0,
        'damages_cost_kobo': 0,
        'cash_sales_kobo': 0,
        'cash_in_kobo': 0,
        'cash_out_kobo': 0,
        'net_cash_movement_kobo': 0,
        'stock_cogs_kobo': 0,
        'stock_expected_closing_kobo': 0,
        'items_sold': 5,
        'shortage_units': 0,
        'reviewed_by': null,
        'reviewed_at': ts,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    final snap = await db.dailyClosingsDao.watchForDay('2026-07-20').first;
    expect(snap, isNotNull);
    expect(snap!.id, id);
    expect(snap.totalSalesKobo, 777000);
    expect(snap.netProfitKobo, 90000);
    expect(snap.itemsSold, 5);
  });

  test('a divergent cloud snapshot never clobbers the local as-reviewed figures '
      '(first-writer-wins on pull)', () async {
    final id = DailyClosingsDao.snapshotId(businessId, '2026-07-20');
    final localTs = DateTime.utc(2026, 7, 21, 8);

    // Insert the local snapshot DIRECTLY (no outbox entry), so this proves the
    // restore's insertOrIgnore — not the invariant-#12 pending-row clobber guard.
    await db.into(db.dailyClosings).insert(
          DailyClosingsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            businessDate: '2026-07-20',
            totalSalesKobo: const Value(500000),
            netProfitKobo: const Value(120000),
            reviewedAt: Value(localTs),
            createdAt: Value(localTs),
            lastUpdatedAt: Value(localTs),
          ),
        );

    // A peer device's divergent snapshot for the SAME day arrives with a NEWER
    // last_updated_at — LWW would normally let it win, but first-writer-wins must
    // hold: the row is append/first-write-only.
    final newerTs = DateTime.utc(2026, 7, 22, 8).toIso8601String();
    await sync.restoreTableDataForTesting('daily_closings', [
      {
        'id': id,
        'business_id': businessId,
        'business_date': '2026-07-20',
        'store_scope_id': null,
        'total_sales_kobo': 999999,
        'refunds_kobo': 0,
        'discounts_kobo': 0,
        'cogs_kobo': 0,
        'gross_profit_kobo': 0,
        'net_profit_kobo': 888888,
        'expenses_kobo': 0,
        'damages_cost_kobo': 0,
        'cash_sales_kobo': 0,
        'cash_in_kobo': 0,
        'cash_out_kobo': 0,
        'net_cash_movement_kobo': 0,
        'stock_cogs_kobo': 0,
        'stock_expected_closing_kobo': 0,
        'items_sold': 1,
        'shortage_units': 0,
        'reviewed_by': null,
        'reviewed_at': newerTs,
        'created_at': newerTs,
        'last_updated_at': newerTs,
      },
    ]);

    final snap = await db.dailyClosingsDao.getForDay('2026-07-20');
    expect(snap, isNotNull);
    expect(snap!.totalSalesKobo, 500000,
        reason: 'the first snapshot wins — a divergent pull cannot overwrite it');
    expect(snap.netProfitKobo, 120000);
  });
}
