// topup_void_reversal_test.dart
//
// #173 / PRD #155 — voiding a customer credit top-up posts a reversal payment
// row (through the #169 seam) ALONGSIDE the compensating wallet leg, so the
// voided amount drops out of the reconciliation's "Debts collected (cash)".
// Asserted at the DAO / service transaction boundary against in-memory Drift.
//
// The cash card (recon_data.dart) sums `cashDebtsCollectedKobo` as: for each
// non-voided cash-method `type == 'wallet_topup'` payment row, `+= amountKobo`.
// These tests reproduce that predicate to prove the net after a void is zero.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String staffId;
  late String customerId;
  late CreditLedgerService ledger;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
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

  /// The reconciliation's `cashDebtsCollectedKobo` contribution: non-voided
  /// cash-method `wallet_topup` rows summed on amount. Zero ⇒ dropped out.
  Future<int> cashDebtsCollectedNet() async {
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('wallet_topup')))
        .get();
    return rows
        .where((p) => p.voidedAt == null && p.method.toLowerCase() == 'cash')
        .fold<int>(0, (s, p) => s + p.amountKobo);
  }

  Future<WalletTransactionData> topupWalletTxn() async {
    return (db.select(db.walletTransactions)
          ..where((t) =>
              t.referenceType.isIn(['topup_cash', 'topup_transfer']) &
              t.type.equals('credit')))
        .get()
        .then((rows) => rows.single);
  }

  test('voiding a top-up posts a reversal + compensating wallet leg and drops '
      'the amount from Debts collected', () async {
    await ledger.topup(
      customerId: customerId,
      amountKobo: 10000,
      method: 'cash',
      staffId: staffId,
    );

    // Before void: collected as cash debt, credit balance +10,000.
    expect(await cashDebtsCollectedNet(), 10000);
    expect(await ledger.getBalanceKobo(customerId), 10000);

    final topup = await topupWalletTxn();
    final voided = await ledger.voidTopup(
      walletTxnId: topup.id,
      staffId: staffId,
      reason: 'mistyped amount',
    );
    expect(voided, isTrue);

    // Debts collected nets to zero.
    expect(await cashDebtsCollectedNet(), 0,
        reason: 'a voided collection must drop out of "Debts collected"');

    // A NEGATIVE wallet_topup reversal payment row exists (seam), referencing
    // the same wallet txn, still live (not voided-in-place).
    final payRows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('wallet_topup')))
        .get();
    expect(payRows, hasLength(2));
    final reversal = payRows.firstWhere((p) => p.amountKobo < 0);
    expect(reversal.amountKobo, -10000);
    expect(reversal.walletTxnId, topup.id);
    expect(reversal.voidedAt, isNull);
    // The original payment row is untouched.
    expect(payRows.firstWhere((p) => p.amountKobo > 0).voidedAt, isNull);

    // The compensating wallet leg zeroes the credit balance.
    expect(await ledger.getBalanceKobo(customerId), 0);
    final compLeg = await (db.select(db.walletTransactions)
          ..where((t) => t.referenceType.equals('void')))
        .getSingle();
    expect(compLeg.signedAmountKobo, -10000);
    expect(compLeg.type, 'debit');

    // The original credit is marked voided (metadata retained).
    final origNow = await (db.select(db.walletTransactions)
          ..where((t) => t.id.equals(topup.id)))
        .getSingle();
    expect(origNow.voidedAt, isNotNull);
  });

  test('a transfer top-up void still zeroes the balance (not on the cash card)',
      () async {
    await ledger.topup(
      customerId: customerId,
      amountKobo: 7000,
      method: 'transfer',
      staffId: staffId,
    );
    expect(await cashDebtsCollectedNet(), 0); // transfer never on the cash card

    final topup = await topupWalletTxn();
    expect(await ledger.voidTopup(walletTxnId: topup.id, staffId: staffId),
        isTrue);

    expect(await ledger.getBalanceKobo(customerId), 0);
    final net = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('wallet_topup')))
        .get()
        .then((r) => r.fold<int>(0, (s, p) => s + p.amountKobo));
    expect(net, 0, reason: 'the wallet_topup ledger nets out regardless');
  });

  test('the reversal payment row is enqueued for sync', () async {
    await ledger.topup(
      customerId: customerId,
      amountKobo: 5000,
      method: 'cash',
      staffId: staffId,
    );
    final topup = await topupWalletTxn();
    await ledger.voidTopup(walletTxnId: topup.id, staffId: staffId);

    final reversal = await (db.select(db.paymentTransactions)
          ..where((p) =>
              p.type.equals('wallet_topup') &
              p.amountKobo.isSmallerThanValue(0)))
        .getSingle();
    final enqueued = (await getPendingQueue(db))
        .where((r) => r.actionType == 'payment_transactions:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == reversal.id)
        .toList();
    expect(enqueued, hasLength(1));
    expect(enqueued.single['amount_kobo'], -5000);
  });

  test('voiding twice is idempotent (second call is a no-op)', () async {
    await ledger.topup(
      customerId: customerId,
      amountKobo: 5000,
      method: 'cash',
      staffId: staffId,
    );
    final topup = await topupWalletTxn();

    expect(await ledger.voidTopup(walletTxnId: topup.id, staffId: staffId),
        isTrue);
    expect(await ledger.voidTopup(walletTxnId: topup.id, staffId: staffId),
        isFalse,
        reason: 'an already-voided top-up cannot be voided again');

    // Still exactly one reversal — no double-reversal.
    final reversals = await (db.select(db.paymentTransactions)
          ..where((p) =>
              p.type.equals('wallet_topup') &
              p.amountKobo.isSmallerThanValue(0)))
        .get();
    expect(reversals, hasLength(1));
    expect(await cashDebtsCollectedNet(), 0);
  });

  test('a non-top-up wallet entry is not voidable through this path', () async {
    // Post a spendable refund credit (not a top-up).
    final refundId = UuidV7.generate();
    final wallet = await db.customerWalletsDao.getByCustomerId(customerId);
    await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            id: Value(refundId),
            businessId: businessId,
            walletId: wallet!.id,
            customerId: customerId,
            type: 'credit',
            amountKobo: 3000,
            signedAmountKobo: 3000,
            referenceType: 'refund',
            performedBy: Value(staffId),
          ),
        );

    expect(await ledger.voidTopup(walletTxnId: refundId, staffId: staffId),
        isFalse,
        reason: 'only genuine top-ups are voidable here');
    // Untouched.
    final row = await (db.select(db.walletTransactions)
          ..where((t) => t.id.equals(refundId)))
        .getSingle();
    expect(row.voidedAt, isNull);
  });
}
