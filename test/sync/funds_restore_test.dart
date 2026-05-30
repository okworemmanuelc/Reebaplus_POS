// funds_restore_test.dart
//
// Guards the inbound (pull/realtime) restore path for the Funds Register
// tables. They are in _syncedTenantTables (push) and the pull order, but a
// synced table also needs an explicit case in _restoreTableData — without it
// the `default:` branch silently drops the row, so a CEO's Open Day would sync
// UP but never land on a staff device (POS stays blocked). These tests drive
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

  final ts = DateTime.utc(2026, 5, 30, 12).toIso8601String();
  const date = '2026-05-30';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    sync = SupabaseSyncService(db, supabase);

    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId; // for the business-scoped DAO reads
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

  test('funds_accounts / fund_days / fund_transactions restore (not dropped)',
      () async {
    final acctId = UuidV7.generate();

    await sync.restoreTableDataForTesting('funds_accounts', [
      {
        'id': acctId,
        'business_id': businessId,
        'store_id': storeId,
        'account_type': 'cash_till',
        'name': 'Cash Till',
        'account_number': null,
        'is_active': true,
        'is_deleted': false,
        'created_at': ts,
        'last_updated_at': ts,
      }
    ]);
    expect(await db.select(db.fundsAccounts).get(), hasLength(1));

    await sync.restoreTableDataForTesting('fund_days', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'store_id': storeId,
        'business_date': date,
        'status': 'open',
        'opened_by': userId,
        'opened_at': ts,
        'closed_by': null,
        'closed_at': null,
        'created_at': ts,
        'last_updated_at': ts,
      }
    ]);
    final day = await db.fundDaysDao.getDay(storeId, date);
    expect(day, isNotNull);
    expect(day!.status, 'open');
    // The POS gate would now see the day as open.
    expect(await db.fundDaysDao.watchIsDayOpen(storeId, date).first, isTrue);

    await sync.restoreTableDataForTesting('fund_transactions', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'funds_account_id': acctId,
        'store_id': storeId,
        'business_date': date,
        'type': 'credit',
        'amount_kobo': 500000,
        'signed_amount_kobo': 500000,
        'reference_type': 'opening',
        'order_id': null,
        'payment_id': null,
        'performed_by': userId,
        'voided_at': null,
        'voided_by': null,
        'void_reason': null,
        'created_at': ts,
        'last_updated_at': ts,
      }
    ]);
    expect(await db.fundTransactionsDao.getBalanceFor(acctId, date), 500000);
  });
}
