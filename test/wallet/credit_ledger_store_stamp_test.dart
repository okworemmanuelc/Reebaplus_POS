// credit_ledger_store_stamp_test.dart
//
// #194 / PRD #155 US 36 — every NEW `payment_transactions` row is stamped with
// `store_id`. Two CreditLedgerService insert sites used to leave it NULL:
//   • the `wallet_topup` row (Add Credit / repayment collection), and
//   • `postCashRow`, the §18.3 cash-out `refund` row.
//
// A null store makes `reconStoreFilter` (recon_data.dart:98) return false under
// a locked store, so a §18.3 customer cash refund silently vanished from the
// Sales card whenever a store was locked, while staying visible under All
// Stores. These tests pin the stamp on BOTH the local row and the pushed
// payload (a store that only exists locally converges nowhere).
//
// Companion to test/payments/reversal_payment_seam_test.dart, which pins the
// same guarantee for the compensating-reversal seam.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String customerId;
  late CreditLedgerService ledger;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Manager',
            pin: '0000',
          ),
        );
    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(name: 'Ada', businessId: businessId),
    );
    ledger = CreditLedgerService(db);
  });

  tearDown(() => db.close());

  /// Every pushed `payment_transactions` payload, newest last.
  Future<List<Map<String, dynamic>>> pushedPayments() async {
    final pending = await getPendingQueue(db);
    return pending
        .where((r) => r.actionType == 'payment_transactions:upsert')
        .map(decodePayload)
        .toList();
  }

  /// Posts a raw wallet row (sets up a held deposit / a debt without a sale).
  Future<void> postRaw(int signed, String type, String refType) async {
    final wallet = await db.customerWalletsDao.getByCustomerId(customerId);
    await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            businessId: businessId,
            walletId: wallet!.id,
            customerId: customerId,
            type: type,
            amountKobo: signed.abs(),
            signedAmountKobo: signed,
            referenceType: refType,
          ),
        );
  }

  group('topup (Add Credit / repayment collection)', () {
    test('stamps the active store on the wallet_topup payment row', () async {
      await ledger.topup(
        customerId: customerId,
        amountKobo: 10000,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      );

      final row = await db.select(db.paymentTransactions).getSingle();
      expect(row.type, 'wallet_topup');
      expect(row.storeId, storeId,
          reason: 'US 36: every new payment row carries its store');

      final pushed = await pushedPayments();
      expect(pushed, hasLength(1));
      expect(pushed.single['store_id'], storeId,
          reason: 'the stamp must reach the cloud, not just the local row');
    });

    test('a store-less call still writes the row (All Stores / no store)',
        () async {
      await ledger.topup(
        customerId: customerId,
        amountKobo: 10000,
        method: 'cash',
        staffId: staffId,
      );

      final row = await db.select(db.paymentTransactions).getSingle();
      expect(row.storeId, isNull);
    });
  });

  group('refundCash (§18.3 cash out)', () {
    test('stamps the active store on the deposit refund row', () async {
      await postRaw(250000, 'credit', 'crate_deposit'); // held 250,000

      final refunded = await ledger.refundCash(
        customerId: customerId,
        amountKobo: 250000,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      );

      expect(refunded, 250000);
      final row = await db.select(db.paymentTransactions).getSingle();
      // #190 retyped this leg: a deposit release is a NEGATIVE `crate_deposit`,
      // not a `refund`. The store stamp (#194) is unchanged by that.
      expect(row.type, 'crate_deposit');
      expect(row.storeId, storeId,
          reason: 'a store-less cash-out vanishes from the store-scoped money '
              'reports under a locked store (#194)');

      final pushed = await pushedPayments();
      expect(pushed, hasLength(1));
      expect(pushed.single['store_id'], storeId);
    });

    test('stamps BOTH cash-out legs when deposit and credit are refunded',
        () async {
      await postRaw(250000, 'credit', 'crate_deposit'); // held 250,000
      await ledger.topup(
        customerId: customerId,
        amountKobo: 5000,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      ); // spendable 5,000

      await ledger.refundCash(
        customerId: customerId,
        amountKobo: 255000,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      );

      // #190 — the deposit leg is a negative `crate_deposit`, the credit leg a
      // `refund`. Both are cash-out rows and both must carry the store.
      final cashOut = await (db.select(db.paymentTransactions)
            ..where((p) =>
                p.type.equals('refund') | p.type.equals('crate_deposit')))
          .get();
      expect(cashOut, hasLength(2),
          reason: 'deposit portion + credit portion');
      expect(cashOut.every((p) => p.storeId == storeId), isTrue,
          reason: 'every leg is stamped, not just the first');
    });
  });
}
