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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    approvalService = CrateReturnApprovalService(db);
    db.businessIdResolver = () => businessId;

    // Seed required data. v29: crate tracking is keyed by MANUFACTURER (§13.4),
    // so no crate_size_groups row is needed for the balance/ledger flows.
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: const Value(businessId), name: 'Test Biz'));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Test User',
          pin: '1234',
        ));
    await db.into(db.customers).insert(CustomersCompanion.insert(
        id: const Value(customerId), businessId: businessId, name: 'Test Customer'));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: const Value(manufacturerId),
        businessId: businessId,
        name: 'Test Mfr'));
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
        quantity: 10,
        performedBy: userId,
      );

      // Verify FKs still ON
      final fkStatusAfter =
          await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fkStatusAfter.read<int>('foreign_keys'), 1);

      // Verify ledger (manufacturer-owned: customer_id null)
      final ledger = await db.select(db.crateLedger).get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -10);
      expect(ledger.first.manufacturerId, manufacturerId);
      expect(ledger.first.customerId, isNull);

      // Verify cache (one row per manufacturer)
      final balances = await db.select(db.manufacturerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -10);
    });
  });

  group('recordCrateReturnByCustomer', () {
    test('customer row carries both owner + manufacturer; balance per mfr',
        () async {
      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 3,
        performedBy: userId,
      );

      final ledger = await db.select(db.crateLedger).get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -3);
      expect(ledger.first.customerId, customerId);
      expect(ledger.first.manufacturerId, manufacturerId);

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.customerId, customerId);
      expect(balances.first.manufacturerId, manufacturerId);
      expect(balances.first.balance, -3);
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
        manufacturerId: manufacturerId,
        quantity: 5,
      );

      await approvalService.approve(returnId, userId);

      // Verify Pending Return status
      final pending = await db.pendingCrateReturnsDao.getById(returnId);
      expect(pending?.status, 'approved');

      // Verify Ledger row. v29: a customer crate row sets BOTH the customer
      // (owner) and the manufacturer (whose crates).
      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows.length, 1);
      final row = ledgerRows.first;
      expect(row.quantityDelta, -5); // Negative as customer returned them
      expect(row.referenceReturnId, returnId);
      expect(row.customerId, customerId);
      expect(row.manufacturerId, manufacturerId);

      // Verify Cache (keyed by customer + manufacturer)
      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.manufacturerId, manufacturerId);
      expect(balances.first.balance, -5);
    });

    test('reject() updates status but appends zero ledger rows', () async {
      final returnId = await db.pendingCrateReturnsDao.createPendingReturn(
        orderId: null,
        customerId: customerId,
        submittedBy: userId,
        manufacturerId: manufacturerId,
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

  // Regression: raw-SQL writes must not store SQLite text (CURRENT_TIMESTAMP)
  // into the INTEGER-epoch last_updated_at columns. drift reads those columns
  // via int.parse, so a text value throws `FormatException: Invalid radix-10
  // number` on the next read of the row.
  group('last_updated_at stays integer epoch (FormatException regression)', () {
    test('addEmptyCrates increments stock and re-reads manufacturer cleanly',
        () async {
      await db.inventoryDao.addEmptyCrates(manufacturerId, 7);

      // Before the fix this read threw FormatException because the customUpdate
      // had stored a "YYYY-MM-DD HH:MM:SS" text into last_updated_at.
      final mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      expect(mfr.emptyCrateStock, 7);

      // Column physically holds an integer, not text.
      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM manufacturers WHERE id = ?",
            variables: [const Variable(manufacturerId)],
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });

    test('second customer return hits ON CONFLICT path and re-reads cleanly',
        () async {
      // First return: INSERT path (uses the integer column default).
      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 2,
        performedBy: userId,
      );
      // Second return for the SAME (customer, manufacturer): the DO UPDATE SET
      // branch ran `last_updated_at = CURRENT_TIMESTAMP` before the fix and
      // corrupted the row; the read-back inside the method threw.
      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 3,
        performedBy: userId,
      );

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -5); // -(2) + -(3)

      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM customer_crate_balances",
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });

    test('second approve hits ON CONFLICT path and re-reads cleanly', () async {
      Future<void> approveOne(int qty) async {
        final id = await db.pendingCrateReturnsDao.createPendingReturn(
          orderId: null,
          customerId: customerId,
          submittedBy: userId,
          manufacturerId: manufacturerId,
          quantity: qty,
        );
        await approvalService.approve(id, userId);
      }

      await approveOne(4); // INSERT path
      await approveOne(6); // ON CONFLICT DO UPDATE SET path

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -10);

      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM customer_crate_balances",
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });
  });

  group('CHECK Constraints', () {
    test('v29: ALLOWS both customer_id and manufacturer_id (relaxed owner CHECK)',
        () async {
      await db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            customerId: const Value(customerId),
            manufacturerId: const Value(manufacturerId),
            quantityDelta: 10,
            movementType: 'issued',
          ));
      final rows = await db.select(db.crateLedger).get();
      expect(rows.length, 1);
      expect(rows.first.customerId, customerId);
      expect(rows.first.manufacturerId, manufacturerId);
    });

    test('throws when neither customer_id nor manufacturer_id are set',
        () async {
      expect(
        () => db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              customerId: const Value.absent(),
              manufacturerId: const Value.absent(),
              quantityDelta: 10,
              movementType: 'issued',
            )),
        throwsA(anything),
      );
    });
  });
}
