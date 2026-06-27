import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Bootstraps a staff user (so performed_by FKs resolve) plus a customer +
/// wallet (so CreditLedgerService.topup has a wallet to write against).
/// Returns (customerId, staffId).
Future<({String customerId, String staffId})> _seedTopupFixtures(
  AppDatabase db,
  String businessId,
) async {
  final staffId = UuidV7.generate();
  final customerId = UuidV7.generate();
  final walletId = UuidV7.generate();

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Test Staff',
          pin: '0000',
        ),
      );
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: Value(customerId),
          businessId: businessId,
          name: 'Topup Tina',
        ),
      );
  await db.into(db.customerWallets).insert(
        CustomerWalletsCompanion.insert(
          id: Value(walletId),
          businessId: businessId,
          customerId: customerId,
        ),
      );
  return (customerId: customerId, staffId: staffId);
}

void main() {
  late AppDatabase db;
  late String businessId;
  late CreditLedgerService creditLedgerService;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    creditLedgerService = CreditLedgerService(db);
  });

  tearDown(() => db.close());

  group('CreditLedgerService.topup dispatch', () {
    test('flag OFF: enqueues two upsert rows, no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.wallet_topup', on: false);
      final fx = await _seedTopupFixtures(db, businessId);

      await creditLedgerService.topup(
        customerId: fx.customerId,
        amountKobo: 50000,
        method: 'cash',
        staffId: fx.staffId,
      );

      final walTxns = await db.select(db.walletTransactions).get();
      expect(walTxns, hasLength(1), reason: 'one local wallet txn');
      final payTxns = await db.select(db.paymentTransactions).get();
      expect(payTxns, hasLength(1), reason: 'one local payment txn');

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(
        actionTypes,
        ['payment_transactions:upsert', 'wallet_transactions:upsert'],
      );
    });

    test('flag ON (cash): one envelope with topup_cash reference type',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.wallet_topup', on: true);
      final fx = await _seedTopupFixtures(db, businessId);

      await creditLedgerService.topup(
        customerId: fx.customerId,
        amountKobo: 25000,
        method: 'cash',
        staffId: fx.staffId,
      );

      // Local rows still present.
      final walTxns = await db.select(db.walletTransactions).get();
      expect(walTxns, hasLength(1));
      final payTxns = await db.select(db.paymentTransactions).get();
      expect(payTxns, hasLength(1));

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_wallet_topup');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      expect(payload['p_customer_id'], fx.customerId);
      expect(payload['p_amount_kobo'], 25000);
      expect(payload['p_method'], 'cash');
      expect(payload['p_reference_type'], 'topup_cash');

      // Idempotency keys must match the local rows so a server replay
      // recognises this as a retry, not a new write.
      expect(payload['p_wallet_txn_id'], walTxns.first.id);
      expect(payload['p_payment_id'], payTxns.first.id);
    });

    test('flag ON (transfer): reference type flips to topup_transfer',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.wallet_topup', on: true);
      final fx = await _seedTopupFixtures(db, businessId);

      await creditLedgerService.topup(
        customerId: fx.customerId,
        amountKobo: 100000,
        method: 'transfer',
        staffId: fx.staffId,
      );

      final pending = await getPendingQueue(db);
      final payload = decodePayload(pending.first);
      expect(payload['p_method'], 'transfer');
      expect(payload['p_reference_type'], 'topup_transfer');
    });

    test('topup throws if customer has no wallet', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.wallet_topup', on: true);
      // Seed a staff user so the topup call can attribute performed_by, but
      // pass a bogus customer id so the wallet lookup fails before any
      // writes occur.
      final fx = await _seedTopupFixtures(db, businessId);

      Object? caught;
      try {
        await creditLedgerService.topup(
          customerId: UuidV7.generate(),
          amountKobo: 1000,
          method: 'cash',
          staffId: fx.staffId,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());

      final pending = await getPendingQueue(db);
      expect(
        pending,
        isEmpty,
        reason: 'no envelope must land when client-side validation fails',
      );
    });
  });
}
