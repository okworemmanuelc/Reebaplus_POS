import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/crate_return_approval_service.dart';
import 'package:drift/drift.dart' hide isNull;

void main() {
  late AppDatabase db;
  late CrateReturnApprovalService approvalService;

  const businessId = 'biz-123';
  const userId = 'user-456';
  const customerId = 'cust-789';
  const manufacturerId = 'mfr-001';
  const crateGroupId = 'group-crate-12';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    approvalService = CrateReturnApprovalService(db);
    db.businessIdResolver = () => businessId;

    // Seed required data
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: const Value(businessId), name: 'Test Biz'));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Test User',
          pin: '1234',
          role: 'ceo',
        ));
    await db.into(db.customers).insert(CustomersCompanion.insert(
        id: const Value(customerId), businessId: businessId, name: 'Test Customer'));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: const Value(manufacturerId),
        businessId: businessId,
        name: 'Test Mfr'));
    await db.into(db.crateGroups).insert(CrateGroupsCompanion.insert(
        id: const Value(crateGroupId),
        businessId: businessId,
        name: '12-Pack',
        size: 12));
  });

  tearDown(() async {
    await db.close();
  });

  group('recordCrateReturnByManufacturer', () {
    test('does not toggle foreign keys and updates ledger + cache', () async {
      // Assert FKs are ON
      final fkStatus = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fkStatus.read<int>('foreign_keys'), 1);

      await db.crateLedgerDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerId,
        crateGroupId: crateGroupId,
        quantity: 10,
        performedBy: userId,
      );

      // Verify FKs still ON
      final fkStatusAfter =
          await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fkStatusAfter.read<int>('foreign_keys'), 1);

      // Verify ledger
      final ledger = await db.select(db.crateLedger).get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -10);
      expect(ledger.first.manufacturerId, manufacturerId);
      expect(ledger.first.customerId, isNull);

      // Verify cache
      final balances = await db.select(db.manufacturerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -10);
    });
  });

  group('CrateReturnApprovalService', () {
    test(
        'approve() appends ledger row and updates cache with explicit field assertions',
        () async {
      final returnId = await db.pendingCrateReturnsDao.createPendingReturn(
        orderId: null,
        customerId: customerId,
        submittedBy: userId,
        crateGroupId: crateGroupId,
        quantity: 5,
      );

      await approvalService.approve(returnId, userId);

      // Verify Pending Return status
      final pending = await db.pendingCrateReturnsDao.getById(returnId);
      expect(pending?.status, 'approved');

      // Verify Ledger row (Explicit field assertions per spec)
      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows.length, 1);
      final row = ledgerRows.first;
      expect(row.quantityDelta, -5); // Negative as customer returned them
      expect(row.referenceReturnId, returnId);
      expect(row.manufacturerId, isNull); // Spec requirement
      expect(row.customerId, customerId); // Spec requirement

      // Verify Cache
      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -5);
    });

    test('reject() updates status but appends zero ledger rows', () async {
      final returnId = await db.pendingCrateReturnsDao.createPendingReturn(
        orderId: null,
        customerId: customerId,
        submittedBy: userId,
        crateGroupId: crateGroupId,
        quantity: 5,
      );

      await approvalService.reject(returnId, userId, 'Too few crates');

      final pending = await db.pendingCrateReturnsDao.getById(returnId);
      expect(pending?.status, 'rejected');
      expect(pending?.rejectionReason, 'Too few crates');

      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows.length, 0);
    });
  });

  group('CHECK Constraints', () {
    test('throws when both customer_id and manufacturer_id are set', () async {
      expect(
        () => db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              customerId: const Value(customerId),
              manufacturerId: const Value(manufacturerId),
              crateGroupId: crateGroupId,
              quantityDelta: 10,
              movementType: 'issued',
            )),
        throwsA(anything), // Drift/Sqlite constraint exception
      );
    });

    test('throws when neither customer_id nor manufacturer_id are set',
        () async {
      expect(
        () => db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              customerId: const Value.absent(),
              manufacturerId: const Value.absent(),
              crateGroupId: crateGroupId,
              quantityDelta: 10,
              movementType: 'issued',
            )),
        throwsA(anything),
      );
    });
  });
}
