import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import '../helpers/dispatch_test_utils.dart';

/// #176 (PRD #155 story 7) — forfeit income. `watchForfeitRows` is the narrow
/// data source the Daily Reconciliation sums IN PERIOD as income: only live
/// (non-voided) `crate_deposit_forfeited` wallet rows. Exercised at the
/// DAO/in-memory-Drift seam.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  Future<(String walletId, String customerId)> seedCustomer() async {
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    final wallet = await (db.select(db.customerWallets)
          ..where((w) => w.customerId.equals(customerId)))
        .getSingle();
    return (wallet.id, customerId);
  }

  Future<void> addRow(
    String walletId,
    String customerId,
    String referenceType,
    int signed, {
    DateTime? voidedAt,
  }) async {
    await db.into(db.walletTransactions).insert(WalletTransactionsCompanion.insert(
        businessId: businessId,
        walletId: walletId,
        customerId: customerId,
        type: signed >= 0 ? 'credit' : 'debit',
        amountKobo: signed.abs(),
        signedAmountKobo: signed,
        referenceType: referenceType,
        voidedAt: Value(voidedAt)));
  }

  test('returns only live crate_deposit_forfeited rows', () async {
    final (walletId, customerId) = await seedCustomer();
    // A live forfeit (debit), a voided forfeit, and non-forfeit family rows.
    await addRow(walletId, customerId, 'crate_deposit_forfeited', -15000);
    await addRow(walletId, customerId, 'crate_deposit_forfeited', -5000,
        voidedAt: DateTime(2026, 7, 20));
    await addRow(walletId, customerId, 'crate_deposit', 20000);
    await addRow(walletId, customerId, 'crate_deposit_refunded', -8000);

    final rows = await db.walletTransactionsDao.watchForfeitRows().first;
    expect(rows, hasLength(1));
    expect(rows.single.referenceType, 'crate_deposit_forfeited');
    expect(rows.single.voidedAt, isNull);
    // The report reads forfeit income as the absolute value of the debit.
    expect(-rows.single.signedAmountKobo, 15000);
  });

  test('is empty for a business with no forfeits', () async {
    final (walletId, customerId) = await seedCustomer();
    await addRow(walletId, customerId, 'crate_deposit', 10000);
    final rows = await db.walletTransactionsDao.watchForfeitRows().first;
    expect(rows, isEmpty);
  });
}
