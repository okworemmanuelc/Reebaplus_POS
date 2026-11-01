// #629 (S4 of PRD #620) — empties in parts.
//
// Selling half a crate issues half a crate of empties, returns can be in
// parts, and every crate deposit is proportional: half a crate = half the
// per-crate rate, rounded half up to the whole kobo (`lineTotalKobo`). Whole
// numbers behave exactly as before.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortage.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_totals.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  // An odd rate, so half a crate lands on half a kobo and the rounding shows.
  const oddRate = 25001;

  group('pure rules', () {
    test('deposit is proportional and rounds half up to the kobo', () {
      SaleCrateLine line(double crates) =>
          SaleCrateLine(manufacturerId: 'm', crates: crates, rateKobo: oddRate);
      expect(line(0.5).fullDepositKobo, 12501); // 12500.5 -> 12501
      expect(line(0.25).fullDepositKobo, 6250); // 6250.25 -> 6250
      expect(line(1.5).fullDepositKobo, 37502); // 37501.5 -> 37502
      expect(line(2).fullDepositKobo, 50002); // whole: unchanged
    });

    test('the returned-count field reads quarters; anything else is invalid',
        () {
      expect(parseReturnedCrateCount('0.5'), 0.5);
      expect(parseReturnedCrateCount('1,25'), 1.25);
      expect(parseReturnedCrateCount('3'), 3);
      expect(parseReturnedCrateCount(''), 0);
      expect(allCrateCountsValid(['0.5', '2', '']), isTrue);
      expect(allCrateCountsValid(['0.3']), isFalse);
    });

    test('Crate Shortage folds parts and values them proportionally', () {
      final t0 = DateTime(2026, 11, 1, 8);
      final state = foldCrateShortageStateForStore([
        CrateCountMovement(
          storeId: 's',
          movementType: kCrateMovementOpeningCount,
          quantityDelta: 0,
          createdAt: t0,
        ),
        CrateCountMovement(
          storeId: 's',
          movementType: kCrateMovementCount,
          quantityDelta: -1.5,
          createdAt: t0.add(const Duration(hours: 1)),
        ),
        CrateShortageWriteOffEvent(
          storeId: 's',
          crateCount: 0.5,
          ratePerCrateKobo: oddRate,
          createdAt: t0.add(const Duration(hours: 2)),
        ),
      ]);
      expect(state.openCrates, 1.0);
      expect(state.writtenOffCrates, 0.5);
      expect(state.outstandingWriteOffs.single.valueKobo, 12501);

      final brand = CrateShortageBrand(
        manufacturerId: 'm',
        manufacturerName: 'Star',
        ratePerCrateKobo: oddRate,
        byStore: {
          's': const CrateShortageState(
            openCrates: 0.5,
            reversibleCrates: 0,
            outstandingWriteOffs: [],
          ),
        },
      );
      expect(brand.openValueKobo, 12501);
    });

    test('a half-crate write-off books half the snapshotted rate', () {
      final w = CrateShortfallWriteOff(
        manufacturerId: 'm',
        crateCount: 0.5,
        ratePerCrateKobo: oddRate,
        writtenOffAt: DateTime(2026, 11, 1),
        source: CrateWriteOffSource.countShortage,
      );
      expect(w.valueKobo, 12501);
      expect(
        crateForfeitShortfallCrates(
          arrangement: CrateMoneyArrangement.perDelivery,
          keptCrates: 0.5,
        ),
        0.5,
      );
    });

    test('supplier deposit position carries parts', () {
      final p = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: oddRate,
        movements: const [
          CrateDepositMovement(
            movementType: kCrateDepositMovementPlacement,
            signedAmountKobo: 37502,
            crateCount: 1.5,
          ),
        ],
        cratesOwed: 2.5,
        emptiesOnHand: 1.75,
      );
      expect(p.placedCrates, 1.5);
      expect(p.unbackedCrates, 1.0);
      expect(p.unbackedValueKobo, oddRate);
      expect(p.shortfallCrates, 0.75);
      expect(p.shortfallValueKobo, 18751); // 18750.75 -> 18751
    });
  });

  group('sale, return and deposit settlement (Drift)', () {
    late AppDatabase db;
    late String businessId;

    setUp(() async {
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      // The local record-sale path, so createOrder writes order_crate_lines.
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    });

    tearDown(() => db.close());

    Future<
        ({
          String orderId,
          String mfrId,
          String staffId,
          String customerId,
          String storeId,
        })> sell({
      required double crates,
      required int rateKobo,
      required int depositKobo,
    }) async {
      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(storeId),
              businessId: businessId,
              name: 'Main',
            ),
          );
      final staffId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Till',
              pin: '0000',
            ),
          );
      final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
      );
      final mfrId = UuidV7.generate();
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: businessId,
              name: 'Star',
              depositAmountKobo: Value(rateKobo),
            ),
          );
      final productId = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(productId),
              businessId: businessId,
              name: 'Star 60cl',
              retailerPriceKobo: const Value(100000),
              manufacturerId: Value(mfrId),
              unit: const Value('Bottle'),
              trackEmpties: const Value(true),
            ),
          );
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: productId,
              storeId: storeId,
              quantity: const Value(100),
            ),
          );
      final goodsKobo = (100000 * crates).round();
      final orderId = await db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          businessId: businessId,
          orderNumber: 'ORD-${UuidV7.generate()}',
          customerId: Value(customerId),
          totalAmountKobo: goodsKobo + depositKobo,
          netAmountKobo: goodsKobo + depositKobo,
          amountPaidKobo: Value(goodsKobo + depositKobo),
          paymentType: 'cash',
          status: 'pending',
          staffId: Value(staffId),
          storeId: Value(storeId),
        ),
        items: [
          OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: 'placeholder',
            productId: Value(productId),
            storeId: storeId,
            quantity: crates,
            unitPriceKobo: 100000,
            totalKobo: goodsKobo,
          ),
        ],
        customerId: customerId,
        amountPaidKobo: goodsKobo + depositKobo,
        totalAmountKobo: goodsKobo + depositKobo,
        staffId: staffId,
        storeId: storeId,
        crateDepositPaidByManufacturer:
            depositKobo > 0 ? {mfrId: depositKobo} : const {},
      );
      return (
        orderId: orderId,
        mfrId: mfrId,
        staffId: staffId,
        customerId: customerId,
        storeId: storeId,
      );
    }

    Future<double> customerDebt(String customerId, String mfrId) async {
      final debt =
          await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
      return debt
          .where((e) => e.manufacturerId == mfrId)
          .fold<double>(0, (s, e) => s + e.balance);
    }

    Future<double> emptyStock(String mfrId) async =>
        (await (db.select(db.manufacturers)..where((m) => m.id.equals(mfrId)))
                .getSingle())
            .emptyCrateStock;

    Future<Map<String, int>> walletLegs(String orderId) async {
      final rows = await (db.select(db.walletTransactions)
            ..where((t) => t.orderId.equals(orderId)))
          .get();
      return {for (final r in rows) r.referenceType: r.signedAmountKobo};
    }

    test('half a crate sold issues half a crate; a quarter comes back',
        () async {
      final s = await sell(crates: 0.5, rateKobo: oddRate, depositKobo: 0);

      final line = (await db.orderCrateLinesDao.getForOrder(s.orderId)).single;
      expect(line.cratesTaken, 0.5);
      expect(line.depositPaidKobo, 0);
      final issued = await (db.select(db.crateLedger)
            ..where((l) =>
                l.referenceOrderId.equals(s.orderId) &
                l.movementType.equals('issued')))
          .get();
      expect(issued.single.quantityDelta, 0.5);
      expect(await customerDebt(s.customerId, s.mfrId), 0.5);

      await OrderService(db).markAsCompleted(
        s.orderId,
        s.staffId,
        customerId: s.customerId,
        storeId: s.storeId,
        crateReturns: [
          CrateReturnLine(
            manufacturerId: s.mfrId,
            takenCrates: 0.5,
            returnedCrates: 0.25,
            rateKobo: oddRate,
            paidKobo: 0,
          ),
        ],
      );
      expect(await customerDebt(s.customerId, s.mfrId), 0.25);
      expect(await emptyStock(s.mfrId), 0.25);
      final pool =
          await db.cratePoolDao.watchEmptiesPoolByManufacturer().first;
      expect(pool[s.mfrId], 0.25);
    });

    test('1.5 crates on deposit, 1 back: half a crate forfeits half the rate',
        () async {
      // Deposit for 1.5 crates at 25,001 kobo = 37,501.5 -> 37,502.
      final s = await sell(crates: 1.5, rateKobo: oddRate, depositKobo: 37502);
      final line = (await db.orderCrateLinesDao.getForOrder(s.orderId)).single;
      expect(line.cratesTaken, 1.5);
      expect(line.depositPaidKobo, 37502);

      await OrderService(db).markAsCompleted(
        s.orderId,
        s.staffId,
        customerId: s.customerId,
        storeId: s.storeId,
        crateReturns: [
          CrateReturnLine(
            manufacturerId: s.mfrId,
            takenCrates: 1.5,
            returnedCrates: 1,
            rateKobo: oddRate,
            paidKobo: 37502,
          ),
        ],
      );
      final legs = await walletLegs(s.orderId);
      // 0.5 kept x 25,001 = 12,500.5 -> 12,501 forfeited; the rest refunded.
      expect(legs['crate_deposit_forfeited'], -12501);
      expect(legs['crate_deposit_refunded'], -25001);
      expect(legs['crate_refund'], 25001);
      expect(legs.containsKey('adjustment'), isFalse);
      expect(await emptyStock(s.mfrId), 1);
    });

    test('whole crates settle exactly as before', () async {
      final s = await sell(crates: 2, rateKobo: 50000, depositKobo: 100000);
      await OrderService(db).markAsCompleted(
        s.orderId,
        s.staffId,
        customerId: s.customerId,
        storeId: s.storeId,
        crateReturns: [
          CrateReturnLine(
            manufacturerId: s.mfrId,
            takenCrates: 2,
            returnedCrates: 1,
            rateKobo: 50000,
            paidKobo: 100000,
          ),
        ],
      );
      final legs = await walletLegs(s.orderId);
      expect(legs['crate_deposit_forfeited'], -50000);
      expect(legs['crate_deposit_refunded'], -50000);
      expect(legs['crate_refund'], 50000);
    });

    test('a half-crate shortage can be written off by the half', () async {
      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(storeId),
              businessId: businessId,
              name: 'Main',
            ),
          );
      final mfrId = UuidV7.generate();
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: businessId,
              name: 'Star',
              depositAmountKobo: const Value(oddRate),
            ),
          );
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: const Value('u'),
              businessId: businessId,
              name: 'Keeper',
              pin: '0000',
            ),
          );
      final pool = db.cratePoolDao;
      await pool.recordManualCountCorrection(
        manufacturerId: mfrId,
        storeId: storeId,
        performedBy: 'u',
        countedEmpties: 10,
      );
      await pool.recordManualCountCorrection(
        manufacturerId: mfrId,
        storeId: storeId,
        performedBy: 'u',
        countedEmpties: 8.5,
      );
      expect(
        await pool.watchCrateShortageByManufacturer(mfrId).first,
        1.5,
      );
      final id = await pool.writeOffCrateShortage(
        manufacturerId: mfrId,
        storeId: storeId,
        crateCount: 0.5,
        performedBy: 'u',
      );
      expect(id, isNotNull);
      final row = await (db.select(db.crateShortfallWriteoffs)
            ..where((w) => w.id.equals(id!)))
          .getSingle();
      expect(row.crateCount, 0.5);
      expect(await pool.watchCrateShortageByManufacturer(mfrId).first, 1.0);
      // More than is open is refused.
      expect(
        await pool.writeOffCrateShortage(
          manufacturerId: mfrId,
          storeId: storeId,
          crateCount: 1.25,
          performedBy: 'u',
        ),
        isNull,
      );
    });
  });

  group('supplier deposit outflow (Drift)', () {
    const businessId = 'biz-629';
    const storeId = 'store-629';
    const supplierId = 'sup-629';
    const brand = 'mfr-629';
    const rate = 350001;
    late AppDatabase db;

    setUp(() async {
      db = (await bootstrapTestDb()).db;
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'B'),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main',
            ),
          );
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(brand),
              businessId: businessId,
              name: 'Star',
              depositAmountKobo: const Value(rate),
              crateMoneyArrangement:
                  const Value(kCrateMoneyArrangementPerDelivery),
            ),
          );
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: const Value('u'),
              businessId: businessId,
              name: 'Keeper',
              pin: '0000',
            ),
          );
      await db.into(db.suppliers).insert(
            SuppliersCompanion.insert(
              id: const Value(supplierId),
              businessId: businessId,
              name: 'Ade Depot',
            ),
          );
    });

    tearDown(() => db.close());

    test('half a crate received raises half the deposit, kept in parts',
        () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierId,
        manufacturerId: brand,
        quantity: 0.5,
        performedBy: 'u',
        storeId: storeId,
      );
      final req =
          (await db.select(db.supplierCrateDepositRequests).get()).single;
      expect(req.crateCount, 0.5);
      expect(req.requestedAmountKobo, 175001); // 175,000.5 -> 175,001
      expect(req.summary, contains('0.5 crates of Star'));

      expect(
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: req.id,
          decidedBy: 'u',
        ),
        isTrue,
      );
      final dep = (await db.select(db.supplierCrateDeposits).get()).single;
      expect(dep.crateCount, 0.5);
      expect(dep.signedAmountKobo, 175001);

      final positions = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierId)
          .first;
      expect(positions.single.position.cratesOwed, 0.5);
      expect(positions.single.position.placedCrates, 0.5);
      expect(positions.single.position.unbackedCrates, 0);
    });
  });
}
