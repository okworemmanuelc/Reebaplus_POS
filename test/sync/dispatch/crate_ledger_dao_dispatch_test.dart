import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds: staff (FK target for performed_by), customer + manufacturer
/// (FK targets for crate_ledger.{customer_id,manufacturer_id}), and a
/// crate_group (FK target for both balance caches and the ledger row).
/// Returns ids needed by the test bodies.
Future<
    ({
      String staffId,
      String customerId,
      String manufacturerId,
      String crateGroupId,
    })> _seedCrateFixtures(
  AppDatabase db,
  String businessId,
) async {
  final staffId = UuidV7.generate();
  final customerId = UuidV7.generate();
  final manufacturerId = UuidV7.generate();
  final crateGroupId = UuidV7.generate();

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Crate Staff',
          role: 'ceo',
          pin: '0000',
        ),
      );
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: Value(customerId),
          businessId: businessId,
          name: 'Crate Carla',
        ),
      );
  await db.into(db.manufacturers).insert(
        ManufacturersCompanion.insert(
          id: Value(manufacturerId),
          businessId: businessId,
          name: 'Crate Manco',
        ),
      );
  await db.into(db.crateGroups).insert(
        CrateGroupsCompanion.insert(
          id: Value(crateGroupId),
          businessId: businessId,
          name: '12-pack',
          size: 12,
        ),
      );
  return (
    staffId: staffId,
    customerId: customerId,
    manufacturerId: manufacturerId,
    crateGroupId: crateGroupId,
  );
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('CrateLedgerDao.recordCrateReturnByCustomer dispatch', () {
    test('flag OFF: enqueues two upsert rows, no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_crate_return',
          on: false);
      final fx = await _seedCrateFixtures(db, businessId);

      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: fx.customerId,
        crateGroupId: fx.crateGroupId,
        quantity: 5,
        performedBy: fx.staffId,
      );

      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows, hasLength(1));
      final balRows = await db.select(db.customerCrateBalances).get();
      expect(balRows, hasLength(1));
      expect(balRows.first.balance, -5,
          reason: 'returning 5 crates reduces balance by 5');

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(
        actionTypes,
        ['crate_ledger:upsert', 'customer_crate_balances:upsert'],
      );
    });

    test('flag ON: one envelope with owner_kind=customer + thin payload',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_crate_return', on: true);
      final fx = await _seedCrateFixtures(db, businessId);

      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: fx.customerId,
        crateGroupId: fx.crateGroupId,
        quantity: 3,
        performedBy: fx.staffId,
      );

      // Local mirror: ledger + cache balance updated immediately so the UI
      // doesn't wait on the cloud round-trip.
      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows, hasLength(1));
      final balRows = await db.select(db.customerCrateBalances).get();
      expect(balRows, hasLength(1));
      expect(balRows.first.balance, -3);

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_record_crate_return');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      expect(payload['p_owner_kind'], 'customer');
      expect(payload['p_owner_id'], fx.customerId);
      expect(payload['p_crate_group_id'], fx.crateGroupId);
      expect(payload['p_quantity_delta'], -3);
      expect(payload['p_movement_type'], 'returned');

      // p_ledger_id must match the local ledger row id so a server replay
      // recognises this as a retry, not a duplicate write.
      expect(payload['p_ledger_id'], ledgerRows.first.id);

      // No order linkage in this test → optional field omitted.
      expect(payload.containsKey('p_reference_order_id'), isFalse);
    });

    test('flag ON: order linkage flows through as p_reference_order_id',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_crate_return', on: true);
      final fx = await _seedCrateFixtures(db, businessId);
      // crate_ledger.reference_order_id is a real FK — seed an order so the
      // insert doesn't fail with SQLITE_CONSTRAINT_FOREIGNKEY (787).
      final orderId = UuidV7.generate();
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: businessId,
              orderNumber: 'TEST-0001',
              totalAmountKobo: 1000,
              netAmountKobo: 1000,
              paymentType: 'cash',
              status: 'completed',
            ),
          );

      await db.crateLedgerDao.recordCrateReturnByCustomer(
        customerId: fx.customerId,
        crateGroupId: fx.crateGroupId,
        quantity: 1,
        performedBy: fx.staffId,
        orderId: orderId,
      );

      final pending = await getPendingQueue(db);
      final payload = decodePayload(pending.first);
      expect(payload['p_reference_order_id'], orderId);
    });
  });

  group('CrateLedgerDao.recordCrateReturnByManufacturer dispatch', () {
    test('flag OFF: enqueues two upsert rows, no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_crate_return',
          on: false);
      final fx = await _seedCrateFixtures(db, businessId);

      await db.crateLedgerDao.recordCrateReturnByManufacturer(
        manufacturerId: fx.manufacturerId,
        crateGroupId: fx.crateGroupId,
        quantity: 7,
        performedBy: fx.staffId,
      );

      final balRows = await db.select(db.manufacturerCrateBalances).get();
      expect(balRows, hasLength(1));
      expect(balRows.first.balance, -7);

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(
        actionTypes,
        ['crate_ledger:upsert', 'manufacturer_crate_balances:upsert'],
      );
    });

    test('flag ON: one envelope with owner_kind=manufacturer', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_crate_return', on: true);
      final fx = await _seedCrateFixtures(db, businessId);

      await db.crateLedgerDao.recordCrateReturnByManufacturer(
        manufacturerId: fx.manufacturerId,
        crateGroupId: fx.crateGroupId,
        quantity: 4,
        performedBy: fx.staffId,
      );

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_record_crate_return');

      final payload = decodePayload(pending.first);
      expect(payload['p_owner_kind'], 'manufacturer');
      expect(payload['p_owner_id'], fx.manufacturerId);
      expect(payload['p_quantity_delta'], -4);
      // Manufacturer path never carries an order ref.
      expect(payload.containsKey('p_reference_order_id'), isFalse);
    });
  });
}
