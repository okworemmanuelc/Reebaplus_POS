import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

class CrateReturnApprovalService {
  final AppDatabase db;

  CrateReturnApprovalService(this.db);

  Future<List<PendingCrateReturnData>> listPending(String businessId) {
    return (db.select(db.pendingCrateReturns)..where(
          (t) => t.businessId.equals(businessId) & t.status.equals('pending'),
        ))
        .get();
  }

  Future<void> approve(String returnId, String approvedBy) async {
    final pending = await db.pendingCrateReturnsDao.getById(returnId);
    if (pending == null) throw Exception('Pending return not found');
    if (pending.status != 'pending') {
      throw Exception('Return is already ${pending.status}');
    }

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.approve_crate_return',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await db.transaction(() async {
      final now = DateTime.now();
      final ledgerId = UuidV7.generate();

      final pcrComp = PendingCrateReturnsCompanion(
        id: Value(returnId),
        status: const Value('approved'),
        approvedBy: Value(approvedBy),
        approvedAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await (db.update(
        db.pendingCrateReturns,
      )..where((t) => t.id.equals(returnId))).write(pcrComp);

      // Crate legs (crate_ledger + customer_crate_balances) go through the Crate
      // Pool seam (#157) — the sole writer of the crate tables. It records the
      // return stamped with referenceReturnId and, on the flag-off path,
      // enqueues the per-table rows.
      await db.cratePoolDao.recordApprovedCustomerReturn(
        customerId: pending.customerId,
        manufacturerId: pending.manufacturerId,
        returnId: returnId,
        ledgerId: ledgerId,
        quantity: pending.quantity,
        approvedBy: approvedBy,
        useDomainRpc: useDomainRpc,
      );

      if (useDomainRpc) {
        // One envelope settles the ledger + pending row server-side.
        final payload = <String, dynamic>{
          'p_business_id': pending.businessId,
          'p_actor_id': approvedBy,
          'p_pending_return_id': returnId,
          'p_ledger_id': ledgerId,
        };
        await db.syncDao.enqueue(
          'domain:pos_approve_crate_return',
          jsonEncode(payload),
        );
      } else {
        // Full-row enqueue: a partial pending_crate_returns upsert omits NOT NULL
        // customer_id / manufacturer_id / quantity / submitted_by → 23502.
        await db.syncDao.enqueueUpsert(
          'pending_crate_returns',
          pending
              .toCompanion(true)
              .copyWith(
                status: const Value('approved'),
                approvedBy: Value(approvedBy),
                approvedAt: Value(now),
                lastUpdatedAt: Value(now),
              ),
        );
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
      await (db.update(
        db.pendingCrateReturns,
      )..where((t) => t.id.equals(returnId))).write(pcrComp);
      // Full-row enqueue (see approve): a partial upsert would 23502.
      await db.syncDao.enqueueUpsert(
        'pending_crate_returns',
        pending
            .toCompanion(true)
            .copyWith(
              status: const Value('rejected'),
              rejectionReason: Value(rejectionReason),
              lastUpdatedAt: Value(now),
            ),
      );
    });
  }
}
