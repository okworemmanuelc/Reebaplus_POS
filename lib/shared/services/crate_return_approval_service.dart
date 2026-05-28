import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

class CrateReturnApprovalService {
  final AppDatabase db;

  CrateReturnApprovalService(this.db);

  Future<List<PendingCrateReturnData>> listPending(String businessId) {
    return (db.select(db.pendingCrateReturns)
          ..where((t) =>
              t.businessId.equals(businessId) & t.status.equals('pending')))
        .get();
  }

  Future<void> approve(String returnId, String approvedBy) async {
    final pending = await db.pendingCrateReturnsDao.getById(returnId);
    if (pending == null) throw Exception('Pending return not found');
    if (pending.status != 'pending') {
      throw Exception('Return is already ${pending.status}');
    }

    final flagValue = await db.systemConfigDao
        .get('feature.domain_rpcs_v2.approve_crate_return');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await db.transaction(() async {
      final now = DateTime.now();
      final ledgerId = UuidV7.generate();
      // Returning crates reduces what the customer owes. pending.quantity
      // is positive; negate for the ledger + balance increment.
      final delta = -pending.quantity;

      final pcrComp = PendingCrateReturnsCompanion(
        id: Value(returnId),
        status: const Value('approved'),
        approvedBy: Value(approvedBy),
        approvedAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await (db.update(db.pendingCrateReturns)
            ..where((t) => t.id.equals(returnId)))
          .write(pcrComp);

      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: pending.businessId,
        customerId: Value(pending.customerId),
        manufacturerId: const Value.absent(),
        crateSizeGroupId: pending.crateSizeGroupId,
        quantityDelta: delta,
        movementType: 'returned',
        referenceReturnId: Value(returnId),
        performedBy: Value(approvedBy),
        lastUpdatedAt: Value(now),
      );
      await db.into(db.crateLedger).insert(ledgerComp);

      await db.customStatement(
        'INSERT INTO customer_crate_balances (id, business_id, customer_id, crate_size_group_id, balance) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(business_id, customer_id, crate_size_group_id) DO UPDATE SET '
        'balance = balance + excluded.balance, last_updated_at = CURRENT_TIMESTAMP',
        [
          UuidV7.generate(),
          pending.businessId,
          pending.customerId,
          pending.crateSizeGroupId,
          delta
        ],
      );

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': pending.businessId,
          'p_actor_id': approvedBy,
          'p_pending_return_id': returnId,
          'p_ledger_id': ledgerId,
        };
        await db.syncDao
            .enqueue('domain:pos_approve_crate_return', jsonEncode(payload));
      } else {
        await db.syncDao.enqueueUpsert('pending_crate_returns', pcrComp);
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
        final balRow = await (db.select(db.customerCrateBalances)
              ..where((t) =>
                  t.businessId.equals(pending.businessId) &
                  t.customerId.equals(pending.customerId) &
                  t.crateSizeGroupId.equals(pending.crateSizeGroupId)))
            .getSingle();
        await db.syncDao.enqueueUpsert('customer_crate_balances', balRow);
      }
    });
  }

  Future<void> reject(
    String returnId,
    String rejectedBy,
    String rejectionReason,
  ) async {
    final pending = await db.pendingCrateReturnsDao.getById(returnId);
    if (pending == null) throw Exception('Pending return not found');
    if (pending.status != 'pending') {
      throw Exception('Return is already ${pending.status}');
    }

    await db.transaction(() async {
      final now = DateTime.now();
      // Schema has approved_by/approved_at only; populating them on rejection
      // would falsely mark the row as approved. rejectedBy is kept on the API
      // surface for a future schema expansion without a caller-side rename.
      final pcrComp = PendingCrateReturnsCompanion(
        id: Value(returnId),
        status: const Value('rejected'),
        rejectionReason: Value(rejectionReason),
        lastUpdatedAt: Value(now),
      );
      await (db.update(db.pendingCrateReturns)
            ..where((t) => t.id.equals(returnId)))
          .write(pcrComp);
      await db.syncDao.enqueueUpsert('pending_crate_returns', pcrComp);
    });
  }
}
