import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/crate_return_approval_service.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds: staff (FK target for submittedBy/approvedBy), customer,
/// crate_group, and a pending_crate_returns row with status='pending'.
Future<({String staffId, String customerId, String crateGroupId, String pendingId, int quantity})>
    _seedApproveFixtures(AppDatabase db, String businessId) async {
  final staffId = UuidV7.generate();
  final customerId = UuidV7.generate();
  final crateGroupId = UuidV7.generate();
  final pendingId = UuidV7.generate();
  const quantity = 5;

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Approve Staff',
          role: 'ceo',
          pin: '0000',
        ),
      );
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: Value(customerId),
          businessId: businessId,
          name: 'Returner Rita',
        ),
      );
  await db.into(db.crateGroups).insert(
        CrateGroupsCompanion.insert(
          id: Value(crateGroupId),
          businessId: businessId,
          name: 'Crate-A',
          size: 12,
        ),
      );
  await db.into(db.pendingCrateReturns).insert(
        PendingCrateReturnsCompanion.insert(
          id: Value(pendingId),
          businessId: businessId,
          customerId: customerId,
          crateGroupId: crateGroupId,
          quantity: quantity,
          submittedBy: staffId,
        ),
      );
  return (
    staffId: staffId,
    customerId: customerId,
    crateGroupId: crateGroupId,
    pendingId: pendingId,
    quantity: quantity,
  );
}

void main() {
  late AppDatabase db;
  late String businessId;
  late CrateReturnApprovalService service;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    service = CrateReturnApprovalService(db);
  });

  tearDown(() => db.close());

  group('CrateReturnApprovalService.approve dispatch', () {
    test(
        'flag OFF: enqueues pending + ledger + balance upserts, no domain envelope',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.approve_crate_return',
          on: false);
      final fx = await _seedApproveFixtures(db, businessId);

      await service.approve(fx.pendingId, fx.staffId);

      // Local writes: pending row updated, ledger row inserted, balance
      // decremented by `quantity`.
      final pcr = await (db.select(db.pendingCrateReturns)
            ..where((t) => t.id.equals(fx.pendingId)))
          .getSingle();
      expect(pcr.status, 'approved');
      expect(pcr.approvedBy, fx.staffId);

      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows, hasLength(1));
      expect(ledgerRows.first.quantityDelta, -fx.quantity);

      final balanceRows = await db.select(db.customerCrateBalances).get();
      expect(balanceRows, hasLength(1));
      expect(balanceRows.first.balance, -fx.quantity);

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(actionTypes, [
        'crate_ledger:upsert',
        'customer_crate_balances:upsert',
        'pending_crate_returns:upsert',
      ]);
    });

    test('flag ON: one envelope with thin payload + ids match local rows',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.approve_crate_return',
          on: true);
      final fx = await _seedApproveFixtures(db, businessId);

      await service.approve(fx.pendingId, fx.staffId);

      // Local mirrors are present (same as flag-OFF).
      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows, hasLength(1));
      expect(ledgerRows.first.quantityDelta, -fx.quantity);
      final balanceRows = await db.select(db.customerCrateBalances).get();
      expect(balanceRows.first.balance, -fx.quantity);

      // Queue: exactly one envelope.
      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_approve_crate_return');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      expect(payload['p_pending_return_id'], fx.pendingId);
      // Idempotency key: server replay must recognise this is the same
      // ledger row already mirrored locally.
      expect(payload['p_ledger_id'], ledgerRows.first.id);
    });

    test('already-approved: throws, no enqueues', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.approve_crate_return',
          on: true);
      final fx = await _seedApproveFixtures(db, businessId);

      // Pre-approve so the pre-flight check throws.
      await (db.update(db.pendingCrateReturns)
            ..where((t) => t.id.equals(fx.pendingId)))
          .write(const PendingCrateReturnsCompanion(
        status: Value('approved'),
      ));

      Object? caught;
      try {
        await service.approve(fx.pendingId, fx.staffId);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);

      final pending = await getPendingQueue(db);
      expect(pending, isEmpty,
          reason: 'no envelope must land for an already-approved return');
    });
  });
}
