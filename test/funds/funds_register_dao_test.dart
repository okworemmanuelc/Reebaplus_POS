import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Funds Register Phase 1 data layer (master plan §23). Locks in account
/// auto-create, Open Day (header + per-account opening credits), the gate
/// stream, balance sums, and the §5 sync-leak invariant.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String userId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Tester',
            pin: '0000',
          ),
        );
  });

  tearDown(() => db.close());

  group('FundsAccountsDao', () {
    test('ensureCashTill is idempotent — two calls yield one Cash Till',
        () async {
      final a = await db.fundsAccountsDao.ensureCashTill(storeId);
      final b = await db.fundsAccountsDao.ensureCashTill(storeId);
      expect(a.id, b.id);
      expect(a.accountType, 'cash_till');
      final all = await db.fundsAccountsDao.getActiveAccountsForStore(storeId);
      expect(all.where((x) => x.accountType == 'cash_till'), hasLength(1));
    });

    test('createAccount + softDeleteAccount enqueue funds_accounts upserts',
        () async {
      final id = await db.fundsAccountsDao.createAccount(
        storeId: storeId,
        accountType: 'pos_machine',
        name: 'POS 1',
      );
      var pending = await getPendingQueue(db);
      expect(pending.last.actionType, 'funds_accounts:upsert');
      expect(decodePayload(pending.last)['id'], id);

      await db.delete(db.syncQueue).go();
      await db.fundsAccountsDao.softDeleteAccount(id);
      pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'funds_accounts:upsert');
      expect(decodePayload(pending.first)['is_deleted'], true);

      // Soft-deleted account drops out of the active list.
      final active = await db.fundsAccountsDao.getActiveAccountsForStore(storeId);
      expect(active.where((x) => x.id == id), isEmpty);
    });

    test('re-adding a soft-deleted name reactivates the same row, not a crash',
        () async {
      final id = await db.fundsAccountsDao.createAccount(
        storeId: storeId,
        accountType: 'pos_machine',
        name: 'POS 1',
      );
      await db.fundsAccountsDao.softDeleteAccount(id);

      // UNIQUE(store_id, account_type, name) ignores is_deleted, so a naive
      // insert would throw. Instead it reactivates the same row + new number.
      final readded = await db.fundsAccountsDao.createAccount(
        storeId: storeId,
        accountType: 'pos_machine',
        name: 'POS 1',
        accountNumber: 'T-999',
      );
      expect(readded, id);

      final active = await db.fundsAccountsDao.getActiveAccountsForStore(storeId);
      final row = active.singleWhere((x) => x.id == id);
      expect(row.isDeleted, isFalse);
      expect(row.accountNumber, 'T-999');
    });

    test('re-adding an ACTIVE duplicate name throws a friendly StateError',
        () async {
      await db.fundsAccountsDao.createAccount(
        storeId: storeId,
        accountType: 'pos_machine',
        name: 'POS 1',
      );
      expect(
        () => db.fundsAccountsDao.createAccount(
          storeId: storeId,
          accountType: 'pos_machine',
          name: 'POS 1',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('FundDaysDao.openDay', () {
    test('creates the day header + an opening credit per active account',
        () async {
      final till = await db.fundsAccountsDao.ensureCashTill(storeId);
      final pos = await db.fundsAccountsDao.createAccount(
        storeId: storeId,
        accountType: 'pos_machine',
        name: 'POS 1',
      );
      const date = '2026-05-30';

      await db.fundDaysDao.openDay(
        storeId: storeId,
        businessDate: date,
        perAccountOpeningKobo: {till.id: 500000, pos: 0},
        performedBy: userId,
      );

      final days = await db.select(db.fundDays).get();
      expect(days, hasLength(1));
      expect(days.first.status, 'open');

      // One opening credit per active account — even the 0-balance one.
      final txns = await db.select(db.fundTransactions).get();
      expect(txns.where((t) => t.referenceType == 'opening'), hasLength(2));

      expect(await db.fundTransactionsDao.getBalanceFor(till.id, date), 500000);
      expect(await db.fundTransactionsDao.getBalanceFor(pos, date), 0);
    });

    test('watchIsDayOpen flips false → true after openDay', () async {
      await db.fundsAccountsDao.ensureCashTill(storeId);
      const date = '2026-05-30';
      final before =
          await db.fundDaysDao.watchIsDayOpen(storeId, date).first;
      expect(before, isFalse);

      await db.fundDaysDao.openDay(
        storeId: storeId,
        businessDate: date,
        perAccountOpeningKobo: {},
        performedBy: userId,
      );

      final after = await db.fundDaysDao.watchIsDayOpen(storeId, date).first;
      expect(after, isTrue);
    });

    test('a second openDay for the same store/date throws', () async {
      await db.fundsAccountsDao.ensureCashTill(storeId);
      const date = '2026-05-30';
      await db.fundDaysDao.openDay(
        storeId: storeId,
        businessDate: date,
        perAccountOpeningKobo: {},
        performedBy: userId,
      );
      expect(
        () => db.fundDaysDao.openDay(
          storeId: storeId,
          businessDate: date,
          perAccountOpeningKobo: {},
          performedBy: userId,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('openDay enqueues fund_days + fund_transactions upserts (§5)',
        () async {
      await db.fundsAccountsDao.ensureCashTill(storeId);
      await db.delete(db.syncQueue).go(); // drop the ensureCashTill upsert
      await db.fundDaysDao.openDay(
        storeId: storeId,
        businessDate: '2026-05-30',
        perAccountOpeningKobo: {},
        performedBy: userId,
      );
      final actions =
          (await getPendingQueue(db)).map((r) => r.actionType).toSet();
      expect(actions, containsAll(<String>{
        'fund_days:upsert',
        'fund_transactions:upsert',
      }));
    });
  });
}
