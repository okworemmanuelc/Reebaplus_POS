// #171 / #188 Confirm safety — idempotency + seller attribution, at the Order
// module's DAO/service transaction boundary against in-memory Drift (the seam
// the PRD names; prior art: order_module_test.dart's Confirm settlement test).
//
// Asserts external behaviour only — resulting rows, derived balances, and the
// order header — never internal call order:
//   * #188 THE PARTITION: two SEPARATE `AppDatabase` instances both settle the
//     same order while offline, then BOTH outboxes are replayed into a third DB
//     standing in for the cloud. Exactly one refund leg, one pool credit.
//   * The converged double-Confirm (a second Confirm against an order already
//     `completed`) settles the deposit exactly once.
//   * Confirm records `confirmed_by` and leaves the seller's `staff_id`
//     untouched (the sale stays credited to who sold it).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // A crate-tracking business, and the local (v1) record-sale path so
    // createOrder writes order_crate_lines itself.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() => db.close());

  // Seeds a money-track (deposit-held) order for `crates` crates of one brand
  // and returns (orderId, mfrId, sellerId, confirmerId, customerId, storeId).
  Future<
      ({
        String orderId,
        String mfrId,
        String sellerId,
        String confirmerId,
        String customerId,
        String storeId,
        int depositKobo,
      })> seedMoneyTrackOrder({int crates = 5, int rateKobo = 50000}) async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    final sellerId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(sellerId),
        businessId: businessId,
        name: 'Seller',
        pin: '0000'));
    final confirmerId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(confirmerId),
        businessId: businessId,
        name: 'Confirmer',
        pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );

    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: Value(mfrId),
          businessId: businessId,
          name: 'Star',
          depositAmountKobo: Value(rateKobo),
        ));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Star Bottle',
          retailerPriceKobo: const Value(100000),
          manufacturerId: Value(mfrId),
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
        ));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(100),
        ));

    final depositKobo = rateKobo * crates;
    final goodsKobo = 100000 * crates;
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
        staffId: Value(sellerId), // the SELLER
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
      staffId: sellerId,
      storeId: storeId,
      crateDepositPaidByManufacturer: {mfrId: depositKobo},
    );

    return (
      orderId: orderId,
      mfrId: mfrId,
      sellerId: sellerId,
      confirmerId: confirmerId,
      customerId: customerId,
      storeId: storeId,
      depositKobo: depositKobo,
    );
  }

  Future<int> countRefundRows(String orderId) async {
    final rows = await (db.select(db.walletTransactions)
          ..where((t) =>
              t.orderId.equals(orderId) &
              t.referenceType.equals('crate_refund')))
        .get();
    return rows.length;
  }

  Future<int> emptyStock(String mfrId) async {
    final m = await (db.select(db.manufacturers)..where((x) => x.id.equals(mfrId)))
        .getSingle();
    return m.emptyCrateStock;
  }

  group('Idempotency — double Confirm settles the deposit once', () {
    test('a CONVERGED second Confirm (order already completed) is a no-op',
        () async {
      final s = await seedMoneyTrackOrder(crates: 5, rateKobo: 50000);
      final svc = OrderService(db);
      final fullReturn = [
        CrateReturnLine(
          manufacturerId: s.mfrId,
          takenCrates: 5,
          returnedCrates: 5,
          rateKobo: 50000,
          paidKobo: s.depositKobo,
        ),
      ];

      // Device A confirms.
      await svc.markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: fullReturn);

      expect(await countRefundRows(s.orderId), 1);
      expect(await emptyStock(s.mfrId), 5);
      final balAfterFirst =
          await db.walletTransactionsDao.getBalanceKobo(s.customerId);

      // Device B confirms the SAME (now-completed) order — must be a no-op.
      // This is the CONVERGED case only: device B has already pulled
      // `completed`, so the order-status re-read alone stops it. The case the
      // PRD story actually names — both devices offline, both reading `pending`
      // — is the partition group at the bottom of this file (#188).
      await svc.markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: fullReturn);

      expect(await countRefundRows(s.orderId), 1,
          reason: 'deposit refunded once, not twice');
      expect(await emptyStock(s.mfrId), 5,
          reason: 'physical empties credited once, not twice');
      expect(await db.walletTransactionsDao.getBalanceKobo(s.customerId),
          balAfterFirst,
          reason: 'the second Confirm posts no wallet legs');

      final order = await db.ordersDao.findById(s.orderId);
      expect(order!.status, 'completed');
    });

    test('a stamped settlement claim skips the pair even while still pending',
        () async {
      // The per-(order, manufacturer) claim is the guard that survives a
      // partition, so prove it works on its own — with the order left `pending`
      // so the status re-read cannot be what stops the second Confirm.
      final s = await seedMoneyTrackOrder(crates: 5, rateKobo: 50000);
      final fullReturn = [
        CrateReturnLine(
          manufacturerId: s.mfrId,
          takenCrates: 5,
          returnedCrates: 5,
          rateKobo: 50000,
          paidKobo: s.depositKobo,
        ),
      ];

      // Pre-claim the pair, as a peer's already-synced Confirm would have.
      final claimed = await db.orderCrateLinesDao.claimSettlement(
        orderId: s.orderId,
        manufacturerId: s.mfrId,
        settledBy: s.sellerId,
      );
      expect(claimed, isTrue, reason: 'the first claim wins');
      expect(
        await db.orderCrateLinesDao.claimSettlement(
          orderId: s.orderId,
          manufacturerId: s.mfrId,
          settledBy: s.confirmerId,
        ),
        isFalse,
        reason: 'a second claim on the same pair loses',
      );

      await OrderService(db).markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: fullReturn);

      expect(await countRefundRows(s.orderId), 0,
          reason: 'the claimed pair was skipped — no second refund leg');
      expect(await emptyStock(s.mfrId), 0,
          reason: 'the claimed pair was skipped — no second pool credit');
      expect((await db.ordersDao.findById(s.orderId))!.status, 'completed',
          reason: 'the flip still runs; only the settlement is skipped');
    });

    test('markCompleted alone is idempotent (status re-read aborts a re-run)',
        () async {
      final s = await seedMoneyTrackOrder();
      await db.ordersDao.markCompleted(s.orderId, s.confirmerId);
      final first = await db.ordersDao.findById(s.orderId);
      expect(first!.status, 'completed');
      final firstCompletedAt = first.completedAt;

      // A second markCompleted with a different confirmer must not touch it.
      await db.ordersDao.markCompleted(s.orderId, s.sellerId);
      final second = await db.ordersDao.findById(s.orderId);
      expect(second!.confirmedBy, s.confirmerId,
          reason: 'confirmedBy is stamped by the FIRST confirm only');
      expect(second.completedAt, firstCompletedAt,
          reason: 'the second call was a no-op');
    });
  });

  group('Seller attribution — staff_id preserved, confirmed_by recorded', () {
    test('Confirm keeps the seller and records the confirmer separately',
        () async {
      final s = await seedMoneyTrackOrder();
      expect((await db.ordersDao.findById(s.orderId))!.staffId, s.sellerId);

      await OrderService(db).markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: [
            CrateReturnLine(
              manufacturerId: s.mfrId,
              takenCrates: 5,
              returnedCrates: 5,
              rateKobo: 50000,
              paidKobo: s.depositKobo,
            ),
          ]);

      final order = await db.ordersDao.findById(s.orderId);
      expect(order!.staffId, s.sellerId,
          reason: 'the sale stays credited to who sold it (#171)');
      expect(order.confirmedBy, s.confirmerId,
          reason: 'the confirmer is recorded separately on confirmed_by');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // #188 — THE PARTITION. The case PRD #155 US 14 actually names, and the one
  // the old "two devices" test could not reach: two devices BOTH OFFLINE, each
  // reading the order as `pending`, each settling it, each pushing.
  //
  // So this group uses two SEPARATE `AppDatabase` instances that never see each
  // other, then replays BOTH outboxes into a THIRD database standing in for the
  // cloud. The replay is keyed on what the outbox actually enqueued — table +
  // row id — and applies each row as a primary-key upsert, which is exactly what
  // the pusher does (`_transport.upsertRows` with a null conflict target →
  // PostgREST defaults to the PK). Before #188 the two devices minted different
  // ids for every leg, so both rows survived and the cloud held a double refund
  // and a double pool credit.
  // ═══════════════════════════════════════════════════════════════════════════
  group('#188 partition — two offline devices settle the same order', () {
    // One fixture, three databases, identical ids everywhere: the state the two
    // tills genuinely share, because the SALE synced before the partition began.
    late String bizId;
    late String storeId;
    late String sellerId;
    late String confirmerId;
    late String otherConfirmerId;
    late String customerId;
    late String walletId;
    late String mfrId;
    late String productId;
    late String orderId;
    late String crateLineId;
    late String heldLegId;

    const crates = 5;
    const rateKobo = 50000;
    const depositKobo = crates * rateKobo;
    const goodsKobo = crates * 100000;

    setUp(() {
      bizId = UuidV7.generate();
      storeId = UuidV7.generate();
      sellerId = UuidV7.generate();
      confirmerId = UuidV7.generate();
      otherConfirmerId = UuidV7.generate();
      customerId = UuidV7.generate();
      walletId = UuidV7.generate();
      mfrId = UuidV7.generate();
      productId = UuidV7.generate();
      orderId = UuidV7.generate();
      crateLineId = UuidV7.generate();
      heldLegId = UuidV7.generate();
    });

    /// A fresh device holding the CONVERGED post-sale state: a pending crate
    /// order — money-track (its deposit held on the customer's wallet) by
    /// default, or crate-track ([moneyTrack] false: no deposit paid, so the
    /// crates were issued against the customer's balance instead).
    ///
    /// Written with direct inserts and EXPLICIT ids rather than through
    /// `createOrder`, because what matters here is that all three databases
    /// agree on every id — which is what convergence means, and what
    /// `createOrder`'s internally-minted ids would deny us. No insert here
    /// enqueues, so each device's outbox starts empty and holds nothing but its
    /// own Confirm.
    Future<AppDatabase> newDevice({bool moneyTrack = true}) async {
      final depositPaid = moneyTrack ? depositKobo : 0;
      final device = AppDatabase.forTesting(NativeDatabase.memory());
      device.businessIdResolver = () => bizId;
      await device.into(device.businesses).insert(BusinessesCompanion.insert(
            id: Value(bizId),
            name: 'Partition Bar',
            type: const Value('Bar'),
          ));
      await setFlag(device, 'feature.domain_rpcs_v2.record_sale', on: false);
      await device.into(device.stores).insert(StoresCompanion.insert(
          id: Value(storeId), businessId: bizId, name: 'Main'));
      for (final (id, name) in [
        (sellerId, 'Seller'),
        (confirmerId, 'Conf A'),
        (otherConfirmerId, 'Conf B'),
      ]) {
        await device.into(device.users).insert(UsersCompanion.insert(
            id: Value(id), businessId: bizId, name: name, pin: '0000'));
      }
      await device.into(device.customers).insert(CustomersCompanion.insert(
          id: Value(customerId), businessId: bizId, name: 'Buyer'));
      await device.into(device.customerWallets).insert(
          CustomerWalletsCompanion.insert(
              id: Value(walletId), businessId: bizId, customerId: customerId));
      await device.into(device.manufacturers).insert(
          ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: bizId,
              name: 'Star',
              depositAmountKobo: const Value(rateKobo)));
      await device.into(device.products).insert(ProductsCompanion.insert(
            id: Value(productId),
            businessId: bizId,
            name: 'Star Bottle',
            retailerPriceKobo: const Value(100000),
            manufacturerId: Value(mfrId),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
          ));
      await device.into(device.orders).insert(OrdersCompanion.insert(
            id: Value(orderId),
            businessId: bizId,
            orderNumber: 'ORD-PARTITION',
            customerId: Value(customerId),
            totalAmountKobo: goodsKobo + depositPaid,
            netAmountKobo: goodsKobo + depositPaid,
            amountPaidKobo: Value(goodsKobo + depositPaid),
            paymentType: 'cash',
            status: 'pending',
            staffId: Value(sellerId),
            storeId: Value(storeId),
            crateDepositPaidKobo: Value(depositPaid),
          ));
      await device.into(device.orderItems).insert(OrderItemsCompanion.insert(
            businessId: bizId,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: crates,
            unitPriceKobo: 100000,
            totalKobo: goodsKobo,
          ));
      await device.into(device.orderCrateLines).insert(
          OrderCrateLinesCompanion.insert(
              id: Value(crateLineId),
              businessId: bizId,
              orderId: orderId,
              manufacturerId: mfrId,
              cratesTaken: crates,
              depositRateKobo: const Value(rateKobo),
              depositPaidKobo: Value(depositPaid)));
      if (moneyTrack) {
        // The held deposit the sale posted (§13.4 Ring 6) — the liability the
        // settlement resolves.
        await device.into(device.walletTransactions).insert(
            WalletTransactionsCompanion.insert(
                id: Value(heldLegId),
                businessId: bizId,
                walletId: walletId,
                customerId: customerId,
                type: 'credit',
                amountKobo: depositKobo,
                signedAmountKobo: depositKobo,
                referenceType: 'crate_deposit',
                orderId: Value(orderId),
                performedBy: Value(sellerId)));
      } else {
        // Crate-track: the sale ISSUED the crates against the customer's crate
        // balance, and Confirm nets them back.
        await device.cratePoolDao.recordCrateIssueByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: crates,
          performedBy: sellerId,
          orderId: orderId,
        );
        // That verb enqueues (it is a real sale write); the partition starts from
        // a clean outbox, so drop what the SALE queued.
        await device.delete(device.syncQueue).go();
      }
      return device;
    }

    List<CrateReturnLine> fullReturn({bool moneyTrack = true}) => [
          CrateReturnLine(
            manufacturerId: mfrId,
            takenCrates: crates,
            returnedCrates: crates,
            rateKobo: rateKobo,
            paidKobo: moneyTrack ? depositKobo : 0,
          ),
        ];

    /// Replays [device]'s outbox into [cloud] the way the pusher would: one
    /// primary-key upsert per enqueued row, in a fixed FK-safe table order.
    /// Returns the `table:id` of every row the destination REJECTED, so a caller
    /// can assert whether the collapse was silent or loud.
    ///
    /// `created_at` is dropped for the append-only ledgers, exactly as the real
    /// push boundary drops it (`_ledgerCreatedAtScrubTables` /
    /// `kSyncScrubCreatedAtTables`) — the cloud owns that column and treats it as
    /// immutable.
    ///
    /// The destination is a real `AppDatabase`, so it carries the SAME
    /// append-only immutable-column triggers the cloud enforces via
    /// `enforce_append_only`. That is deliberate: a second device's upsert that
    /// would raise P0001 in Postgres also aborts here, instead of quietly
    /// succeeding and flattering the fix.
    ///
    /// `manufacturers` is deliberately NOT replayed: `empty_crate_stock` is off
    /// the push whitelist (#159, ADR 0020), so the pool the cloud can see is
    /// derived from `crate_ledger` alone. Replaying the absolute scalar here
    /// would test a value that never crosses the wire.
    Future<List<String>> replayOutboxInto(
      AppDatabase cloud,
      AppDatabase device,
    ) async {
      final queued = await device.select(device.syncQueue).get();
      final idsByTable = <String, List<String>>{};
      for (final row in queued) {
        final parts = row.actionType.split(':');
        if (parts.length < 2 || parts[1] != 'upsert') continue;
        final id = (jsonDecode(row.payload) as Map<String, dynamic>)['id'];
        if (id is! String) continue;
        idsByTable.putIfAbsent(parts.first, () => []).add(id);
      }
      final rejected = <String>[];
      // Parents before children: the refund payment row references the wallet
      // txn, and every crate/wallet row references the order.
      for (final table in const [
        'orders',
        'order_crate_lines',
        'wallet_transactions',
        'crate_ledger',
        'payment_transactions',
      ]) {
        for (final id in idsByTable[table] ?? const <String>[]) {
          try {
            switch (table) {
              case 'orders':
                final r = await (device.select(device.orders)
                      ..where((t) => t.id.equals(id)))
                    .getSingle();
                await cloud
                    .into(cloud.orders)
                    .insertOnConflictUpdate(r.toCompanion(true));
              case 'order_crate_lines':
                final r = await (device.select(device.orderCrateLines)
                      ..where((t) => t.id.equals(id)))
                    .getSingle();
                await cloud
                    .into(cloud.orderCrateLines)
                    .insertOnConflictUpdate(r.toCompanion(true));
              case 'wallet_transactions':
                final r = await (device.select(device.walletTransactions)
                      ..where((t) => t.id.equals(id)))
                    .getSingle();
                await cloud
                    .into(cloud.walletTransactions)
                    .insertOnConflictUpdate(r
                        .toCompanion(true)
                        .copyWith(createdAt: const Value.absent()));
              case 'crate_ledger':
                final r = await (device.select(device.crateLedger)
                      ..where((t) => t.id.equals(id)))
                    .getSingle();
                await cloud.into(cloud.crateLedger).insertOnConflictUpdate(r
                    .toCompanion(true)
                    .copyWith(createdAt: const Value.absent()));
              case 'payment_transactions':
                final r = await (device.select(device.paymentTransactions)
                      ..where((t) => t.id.equals(id)))
                    .getSingle();
                await cloud
                    .into(cloud.paymentTransactions)
                    .insertOnConflictUpdate(r
                        .toCompanion(true)
                        .copyWith(createdAt: const Value.absent()));
            }
          } on Exception {
            // The append-only guard refused this row. In production that is a
            // failed push → bounded auto-retry → `sync_queue_orphans`, visible on
            // the Sync Issues screen (invariant #12). The destination keeps the
            // row the FIRST device delivered.
            rejected.add('$table:$id');
          }
        }
      }
      return rejected;
    }

    /// Every leg of the crate-deposit settlement family this order carries.
    Future<List<WalletTransactionData>> settlementLegs(
      AppDatabase on,
      String referenceType,
    ) =>
        (on.select(on.walletTransactions)
              ..where((t) =>
                  t.orderId.equals(orderId) &
                  t.referenceType.equals(referenceType)))
            .get();

    /// EVERY customer-less pool credit for this brand — the rows the physical
    /// empties pool is DERIVED from (ADR 0020).
    ///
    /// Deliberately NOT filtered on `reference_order_id`: pre-#188 pool rows
    /// carried no order reference at all, so filtering on it would make this
    /// assertion measure order-stamping (0 rows vs 1) instead of the double
    /// credit (2 rows vs 1) it exists to catch.
    Future<List<CrateLedgerData>> poolCredits(AppDatabase on) =>
        (on.select(on.crateLedger)
              ..where((t) =>
                  t.customerId.isNull() &
                  t.manufacturerId.equals(mfrId) &
                  t.quantityDelta.isBiggerThanValue(0)))
            .get();

    /// The customer-side crate-track return rows (the `else if` branch of the
    /// settlement — no deposit was paid, so the issued count is netted back).
    Future<List<CrateLedgerData>> crateTrackReturns(AppDatabase on) =>
        (on.select(on.crateLedger)
              ..where((t) =>
                  t.referenceOrderId.equals(orderId) &
                  t.customerId.equals(customerId) &
                  t.movementType.equals('returned')))
            .get();

    test('both outboxes converge to ONE refund leg and ONE pool credit',
        () async {
      final tillA = await newDevice();
      final tillB = await newDevice();
      final cloud = await newDevice();
      addTearDown(() async {
        await tillA.close();
        await tillB.close();
        await cloud.close();
      });

      // Neither till can see the other: both read `pending`, both settle.
      for (final till in [tillA, tillB]) {
        await OrderService(till).markAsCompleted(orderId, confirmerId,
            customerId: customerId,
            storeId: storeId,
            crateReturns: fullReturn());
      }

      // Each device really did settle locally — this is not a test that one of
      // them silently no-op'd.
      for (final till in [tillA, tillB]) {
        expect(await settlementLegs(till, 'crate_refund'), hasLength(1));
        expect(await poolCredits(till), hasLength(1));
        expect((await till.ordersDao.findById(orderId))!.status, 'completed');
      }

      // The property that makes the collapse possible: the two devices minted
      // the SAME id for the same leg (#188). Before the fix these were two
      // random UUIDs and everything below doubled.
      expect(
        (await settlementLegs(tillA, 'crate_refund')).single.id,
        (await settlementLegs(tillB, 'crate_refund')).single.id,
        reason: 'the refund leg id is derived from (order, manufacturer, leg)',
      );
      expect(
        (await settlementLegs(tillA, 'crate_deposit_refunded')).single.id,
        (await settlementLegs(tillB, 'crate_deposit_refunded')).single.id,
        reason: 'so is the held-deposit drop',
      );
      expect(
        (await poolCredits(tillA)).single.id,
        (await poolCredits(tillB)).single.id,
        reason: 'and so is the physical pool credit',
      );

      // Both devices come online and push. The cloud upserts on the PK.
      expect(await replayOutboxInto(cloud, tillA), isEmpty);
      expect(await replayOutboxInto(cloud, tillB), isEmpty,
          reason: 'same confirmer ⇒ every guarded column matches ⇒ the second '
              'push is a silent no-op UPDATE, not an append-only violation');

      expect(await settlementLegs(cloud, 'crate_refund'), hasLength(1),
          reason: 'the deposit is refunded ONCE, not twice');
      expect(
          await settlementLegs(cloud, 'crate_deposit_refunded'), hasLength(1),
          reason: 'the held deposit is dropped ONCE');
      expect(await poolCredits(cloud), hasLength(1),
          reason: 'the empties pool is credited ONCE, not twice');
      expect((await poolCredits(cloud)).single.quantityDelta, crates,
          reason: 'the derived pool is 5 crates, not 10');

      // And the customer's wallet lands where a single settlement leaves it:
      // the held deposit came in (+), was dropped (−), and came back as
      // spendable credit (+) — net +deposit, once.
      expect(await cloud.walletTransactionsDao.getBalanceKobo(customerId),
          depositKobo,
          reason: 'one settlement, not two');
    });

    test('DIFFERENT confirmers: the loser is refused, the money still settles '
        'once', () async {
      // The residual documented on `OrdersDao.settlementLegId`, pinned as a test
      // so nobody discovers it in the field. `performed_by` is a guarded
      // append-only column and it is the ONE guarded column two devices can
      // disagree on, so the second device's money legs are REFUSED rather than
      // collapsed. What must hold is that the refusal is the only cost: the
      // destination still ends with exactly one refund leg and one pool credit,
      // never two.
      final tillA = await newDevice();
      final tillB = await newDevice();
      final cloud = await newDevice();
      addTearDown(() async {
        await tillA.close();
        await tillB.close();
        await cloud.close();
      });

      await OrderService(tillA).markAsCompleted(orderId, confirmerId,
          customerId: customerId,
          storeId: storeId,
          crateReturns: fullReturn());
      await OrderService(tillB).markAsCompleted(orderId, otherConfirmerId,
          customerId: customerId,
          storeId: storeId,
          crateReturns: fullReturn());

      expect(await replayOutboxInto(cloud, tillA), isEmpty,
          reason: 'the first device delivers cleanly');
      final refused = await replayOutboxInto(cloud, tillB);

      final refundLegId = (await settlementLegs(tillB, 'crate_refund')).single.id;
      expect(refused, contains('wallet_transactions:$refundLegId'),
          reason: 'the duplicate money leg is refused by the append-only guard '
              '(P0001 cloud-side) — bounded, visible, and NOT a second refund');

      expect(await settlementLegs(cloud, 'crate_refund'), hasLength(1),
          reason: 'STILL refunded once — this is the money assertion');
      expect(
          await settlementLegs(cloud, 'crate_deposit_refunded'), hasLength(1));
      expect(await cloud.walletTransactionsDao.getBalanceKobo(customerId),
          depositKobo,
          reason: 'one settlement, not two');
      // The pool credit carries no `performed_by`, so it collapses cleanly even
      // here — the physical count is never at risk from a confirmer mismatch.
      expect(await poolCredits(cloud), hasLength(1));
      expect((await poolCredits(cloud)).single.quantityDelta, crates);
    });

    test('CRATE-TRACK: the netted return converges to one ledger row',
        () async {
      // The other settlement branch: no deposit was paid, so Confirm nets the
      // issued crate count back instead of moving money. Its ledger row is
      // deterministic for the same reason (#188).
      final tillA = await newDevice(moneyTrack: false);
      final tillB = await newDevice(moneyTrack: false);
      final cloud = await newDevice(moneyTrack: false);
      addTearDown(() async {
        await tillA.close();
        await tillB.close();
        await cloud.close();
      });

      for (final till in [tillA, tillB]) {
        await OrderService(till).markAsCompleted(orderId, confirmerId,
            customerId: customerId,
            storeId: storeId,
            crateReturns: fullReturn(moneyTrack: false));
      }

      expect((await crateTrackReturns(tillA)).single.id,
          (await crateTrackReturns(tillB)).single.id,
          reason: 'the crate-track return row id is deterministic too');
      // Money-track legs must NOT appear on this path (§13.4: paid in crates,
      // settled in crates).
      expect(await settlementLegs(tillA, 'crate_refund'), isEmpty);

      expect(await replayOutboxInto(cloud, tillA), isEmpty);
      expect(await replayOutboxInto(cloud, tillB), isEmpty);

      expect(await crateTrackReturns(cloud), hasLength(1),
          reason: 'the customer is credited the return ONCE, not twice');
      expect(await poolCredits(cloud), hasLength(1),
          reason: 'and the physical pool ONCE');
      final debt =
          await cloud.cratePoolDao.watchCustomerCrateDebt(customerId).first;
      expect(debt.single.balance, 0,
          reason: 'issued 5, returned 5 — the derived debt nets to zero, and a '
              'second Confirm cannot push it to −5');
    });

    test('the CASH refund pays out of the till once', () async {
      final tillA = await newDevice();
      final tillB = await newDevice();
      final cloud = await newDevice();
      addTearDown(() async {
        await tillA.close();
        await tillB.close();
        await cloud.close();
      });

      for (final till in [tillA, tillB]) {
        await OrderService(till).markAsCompleted(orderId, confirmerId,
            customerId: customerId,
            storeId: storeId,
            crateReturns: fullReturn(),
            refundAsCash: true);
      }

      // #190 — the release is a NEGATIVE `crate_deposit`, not a `refund`: it
      // hands back money the till only held, so it must net the held-deposit
      // line down rather than post a sales refund that never happened.
      Future<List<PaymentTransactionData>> releasePayments(AppDatabase on) =>
          (on.select(on.paymentTransactions)
                ..where((t) => t.type.equals('crate_deposit')))
              .get();

      expect(await releasePayments(tillA), hasLength(1));
      expect((await releasePayments(tillA)).single.id,
          (await releasePayments(tillB)).single.id,
          reason: 'the cash release row id is deterministic too (#188)');

      expect(await replayOutboxInto(cloud, tillA), isEmpty);
      expect(await replayOutboxInto(cloud, tillB), isEmpty);

      final payments = await releasePayments(cloud);
      expect(payments, hasLength(1),
          reason: 'cash leaves the till ONCE, not twice');
      expect(payments.single.amountKobo, -depositKobo);
      expect(
          await (cloud.select(cloud.paymentTransactions)
                ..where((t) => t.type.equals('refund')))
              .get(),
          isEmpty,
          reason: 'a deposit release is never a sales refund (#190)');
      // No wallet credit on the cash path — the money left as cash.
      expect(await settlementLegs(cloud, 'crate_refund'), isEmpty);
    });
  });
}
