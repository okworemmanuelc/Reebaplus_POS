// expense_budgets_restore_test.dart
//
// Guards the inbound (pull/realtime) restore path for expense_budgets (§20) and
// stock_counts (§17). Both are in _syncedTenantTables (push) but a synced table
// ALSO needs an entry in _pullOrder + an explicit case in _restoreTableData —
// without it the `default:` branch silently drops the row, so a budget (or a
// saved stock count) set on one device never lands on another. These tests drive
// the @visibleForTesting restore seam against an in-memory DB.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String storeId;
  late String userId;

  final ts = DateTime.utc(2026, 6, 2, 12).toIso8601String();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    sync = SupabaseSyncService(db, supabase);

    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    storeId = UuidV7.generate();
    userId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
        );
    await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(userId),
          businessId: businessId,
          name: 'CEO',
          pin: '0000',
        ));
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test('expense_budgets restore (not dropped) — business-wide + per-store',
      () async {
    await sync.restoreTableDataForTesting('expense_budgets', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'store_id': null, // business-wide goal
        'amount_kobo': 12000000,
        'is_deleted': false,
        'created_at': ts,
        'last_updated_at': ts,
      },
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'store_id': storeId, // per-store goal
        'amount_kobo': 5000000,
        'is_deleted': false,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);

    final rows = await db.select(db.expenseBudgets).get();
    expect(rows, hasLength(2),
        reason: 'incoming budgets must land locally, not hit default: drop');
    expect(rows.firstWhere((r) => r.storeId == null).amountKobo, 12000000);
    expect(rows.firstWhere((r) => r.storeId == storeId).amountKobo, 5000000);
  });

  test('stock_counts restore (not dropped)', () async {
    await sync.restoreTableDataForTesting('stock_counts', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'store_id': storeId,
        'business_date': '2026-06-02',
        'products_counted': 10,
        'shortage_count': 1,
        'surplus_count': 0,
        'shortage_units': 3,
        'surplus_units': 0,
        'lines_json': '[]',
        'counted_by': userId,
        'created_at': ts,
        'last_updated_at': ts,
      }
    ]);

    final rows = await db.select(db.stockCounts).get();
    expect(rows, hasLength(1),
        reason: 'incoming stock counts must land locally');
    expect(rows.single.productsCounted, 10);
  });
}
