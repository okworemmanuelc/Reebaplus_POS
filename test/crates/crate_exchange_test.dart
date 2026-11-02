import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/crate_exchange.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// #649 Empties Exchange (ADR 0033): empties handed over at Checkout net against
/// the crates in the sale inside the sale's transaction. Every data scenario
/// runs on both sale sync paths: v1 per-table rows and the v2 held envelope.
void main() {
  group('the rule', () {
    const taken = {'a': 5.0, 'b': 2.5};

    test('clears only when every brand is covered', () {
      expect(
        crateExchangeClearsSale(taken: taken, returned: {'a': 5, 'b': 2.5}),
        isTrue,
      );
      expect(crateExchangeClearsSale(taken: taken, returned: {'a': 5}), isFalse);
      expect(
        crateExchangeClearsSale(taken: taken, returned: {'a': 4, 'b': 2.5}),
        isFalse,
      );
    });

    test('nothing entered or no crates never clears', () {
      expect(crateExchangeClearsSale(taken: taken, returned: {}), isFalse);
      expect(crateExchangeClearsSale(taken: {}, returned: {}), isFalse);
      expect(crateExchangeClearsSale(taken: {}, returned: {'a': 1}), isFalse);
      expect(
        crateExchangeClearsSale(taken: {'a': 0}, returned: {}),
        isFalse,
        reason: 'nothing entered is never an exchange',
      );
    });

    test('outstanding drops a cleared brand and keeps the order', () {
      expect(outstandingCrates(taken, {'a': 5, 'b': 1}), {'b': 1.5});
      expect(outstandingCrates(taken, {}).keys, ['a', 'b']);
    });

    test('the validator refuses each bad count', () {
      CrateExchangeRefusal? refusal(Map<String, double> returned) =>
          crateExchangeProblem(taken: taken, returned: returned)?.refusal;

      expect(refusal({}), isNull);
      expect(refusal({'a': 5, 'b': 0.25}), isNull);
      expect(refusal({'a': 0}), isNull);
      expect(refusal({'z': 1}), CrateExchangeRefusal.unknownBrand);
      expect(refusal({'a': -1}), CrateExchangeRefusal.negative);
      expect(refusal({'a': 0.3}), CrateExchangeRefusal.notQuarterStep);
      expect(refusal({'a': 5.25}), CrateExchangeRefusal.moreThanTaken);
    });
  });

  group('walk-ins return everything (#656)', () {
    const taken = {'a': 5.0, 'b': 2.5};

    test('every brand covered is no shortfall', () {
      expect(walkInExchangeShortfall(taken: taken, returned: taken), isNull);
      expect(
        walkInExchangeShortfall(taken: taken, returned: {'a': 5, 'b': 2.5}),
        isNull,
      );
    });

    test('a part count names the first short brand', () {
      final short = walkInExchangeShortfall(
        taken: taken,
        returned: {'a': 3, 'b': 1},
      );
      expect(short, (manufacturerId: 'a', taken: 5.0, returned: 3.0));
      final second = walkInExchangeShortfall(
        taken: taken,
        returned: {'a': 5, 'b': 2},
      );
      expect(second, (manufacturerId: 'b', taken: 2.5, returned: 2.0));
    });

    test('a blank brand is short with 0 entered', () {
      expect(walkInExchangeShortfall(taken: taken, returned: {}), (
        manufacturerId: 'a',
        taken: 5.0,
        returned: 0.0,
      ));
      expect(walkInExchangeShortfall(taken: taken, returned: {'a': 5}), (
        manufacturerId: 'b',
        taken: 2.5,
        returned: 0.0,
      ));
    });

    test('nothing countable is never short', () {
      expect(walkInExchangeShortfall(taken: {}, returned: {}), isNull);
      expect(walkInExchangeShortfall(taken: {}, returned: {'a': 1}), isNull);
    });

    test('the refusal text', () {
      expect(
        walkInShortfallMessage('Star', 5, 3),
        'A walk-in must return all 5 Star empties (3 entered).',
      );
      expect(
        walkInShortfallMessage('Star', 1, 0),
        'A walk-in must return all 1 Star empty (0 entered).',
      );
      expect(
        walkInShortfallMessage('Star', 2.5, 0.25),
        'A walk-in must return all 2.5 Star empties (0.25 entered).',
      );
    });
  });

  for (final v2 in [false, true]) {
    group(v2 ? 'v2 held path' : 'v1 path', () {
      late AppDatabase db;
      late String businessId;
      late OrderService service;
      late String storeId;
      late String staffId;
      late String customerId;
      late String starId;
      late String heroId;
      late String starBottle;
      late String heroBottle;

      setUp(() async {
        final boot = await bootstrapTestDb();
        db = boot.db;
        businessId = boot.businessId;
        service = OrderService(db);
        await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
            .write(const BusinessesCompanion(type: Value('Bar')));
        await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: v2);
        await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
        storeId = UuidV7.generate();
        await db
            .into(db.stores)
            .insert(
              StoresCompanion.insert(
                id: Value(storeId),
                businessId: businessId,
                name: 'Main',
              ),
            );
        staffId = UuidV7.generate();
        await db
            .into(db.users)
            .insert(
              UsersCompanion.insert(
                id: Value(staffId),
                businessId: businessId,
                name: 'Cashier',
                pin: '0000',
              ),
            );
        customerId = await db.customersDao.addCustomer(
          CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
        );

        Future<(String, String)> brand(String name) async {
          final mfr = UuidV7.generate();
          await db
              .into(db.manufacturers)
              .insert(
                ManufacturersCompanion.insert(
                  id: Value(mfr),
                  businessId: businessId,
                  name: name,
                  depositAmountKobo: const Value(50000),
                ),
              );
          final product = UuidV7.generate();
          await db
              .into(db.products)
              .insert(
                ProductsCompanion.insert(
                  id: Value(product),
                  businessId: businessId,
                  name: '$name Bottle',
                  retailerPriceKobo: const Value(100000),
                  manufacturerId: Value(mfr),
                  unit: const Value('Bottle'),
                  trackEmpties: const Value(true),
                ),
              );
          await db
              .into(db.inventory)
              .insert(
                InventoryCompanion.insert(
                  businessId: businessId,
                  productId: product,
                  storeId: storeId,
                  quantity: const Value(100),
                ),
              );
          return (mfr, product);
        }

        (starId, starBottle) = await brand('Star');
        (heroId, heroBottle) = await brand('Hero');
      });

      tearDown(() => db.close());

      Map<String, dynamic> line(String productId, double qty) => {
        'id': productId,
        'qty': qty,
        'unitPriceKobo': 100000,
        'name': 'Item',
      };

      Future<OrderData> sell(
        List<Map<String, dynamic>> cart, {
        String? customer,
        Map<String, double> returned = const {},
        Map<String, int> deposits = const {},
      }) async {
        final goods = cart.fold<int>(
          0,
          (s, l) => s + (100000 * (l['qty'] as double)).round(),
        );
        final deposit = deposits.values.fold<int>(0, (s, v) => s + v);
        final number = await service.addOrder(
          customerId: customer,
          cart: cart,
          totalAmountKobo: goods + deposit,
          amountPaidKobo: goods + deposit,
          paymentType: 'cash',
          staffId: staffId,
          storeId: storeId,
          crateDepositPaidKobo: deposit,
          crateDepositPaidByManufacturer: deposits,
          cratesReturnedByManufacturer: returned,
        );
        return (db.select(
          db.orders,
        )..where((o) => o.orderNumber.equals(number))).getSingle();
      }

      Future<void> confirm(OrderData order, List<CrateReturnLine> lines) =>
          service.markAsCompleted(
            order.id,
            staffId,
            customerId: order.customerId,
            storeId: storeId,
            crateReturns: lines,
          );

      Future<Map<String, double>> pool() =>
          db.cratePoolDao.watchEmptiesPoolByManufacturer().first;

      Future<double> debt(String manufacturerId) async {
        final rows = await db.cratePoolDao
            .watchCustomerCrateDebt(customerId)
            .first;
        return rows
            .where((r) => r.manufacturerId == manufacturerId)
            .fold<double>(0, (s, r) => s + r.balance);
      }

      Future<List<CrateLedgerData>> ledger(String orderId) => (db.select(
        db.crateLedger,
      )..where((l) => l.referenceOrderId.equals(orderId))).get();

      Future<double> scalar(String manufacturerId) async =>
          (await (db.select(db.manufacturers)
                    ..where((m) => m.id.equals(manufacturerId)))
                  .getSingle())
              .emptyCrateStock;

      Future<OrderData> reload(String orderId) => (db.select(
        db.orders,
      )..where((o) => o.id.equals(orderId))).getSingle();

      test('nothing entered: pending, and no pool row', () async {
        final order = await sell([line(starBottle, 5)], customer: customerId);
        expect(order.status, 'pending');
        expect(order.completedAt, isNull);
        expect(await pool(), isEmpty);
        expect(await debt(starId), 5);
        expect(
          (await db.orderCrateLinesDao.getForOrder(order.id)).single.cratesTaken,
          5,
        );
      });

      test('full exchange, registered: completes with nothing left', () async {
        final before = DateTime.now().toUtc();
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 5},
        );

        expect(order.status, 'completed');
        expect(order.completedAt, isNotNull);
        expect(
          order.completedAt!.isBefore(before.subtract(const Duration(seconds: 2))),
          isFalse,
        );
        expect(order.confirmedBy, isNull);
        expect(await service.watchPendingOrders().first, isEmpty);
        expect(await db.orderCrateLinesDao.getForOrder(order.id), isEmpty);
        expect(
          (await ledger(order.id)).where((l) => l.movementType == 'issued'),
          isEmpty,
        );
        expect(await pool(), {starId: 5});
        expect(await debt(starId), 0);
      });

      test(
        'walk-in short: refused with the exact text, nothing written',
        () async {
          final before = await db.select(db.orders).get();
          await expectLater(
            sell(
              [line(starBottle, 5), line(heroBottle, 2)],
              returned: {starId: 5, heroId: 1},
            ),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'A walk-in must return all 2 Hero empties (1 entered).',
              ),
            ),
          );
          expect(await db.select(db.orders).get(), hasLength(before.length));
          expect(await db.select(db.crateLedger).get(), isEmpty);
          expect(
            (await db.select(db.syncQueue).get()).where(
              (q) => !q.actionType.startsWith('customer'),
            ),
            isEmpty,
          );
          expect(await pool(), isEmpty);
        },
      );

      test('walk-in with nothing entered: refused with 0 entered', () async {
        await expectLater(
          sell([line(starBottle, 3)]),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'A walk-in must return all 3 Star empties (0 entered).',
            ),
          ),
        );
        expect(await db.select(db.orders).get(), isEmpty);
      });

      test('a van road sale is exempt: it has no empties field', () async {
        await (db.update(db.stores)..where((s) => s.id.equals(storeId))).write(
          const StoresCompanion(kind: Value(kStoreKindVan)),
        );
        final order = await sell([line(starBottle, 3)]);
        expect(order.status, 'pending');
      });

      test('registered part exchange still goes pending', () async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 3},
        );
        expect(order.status, 'pending');
        expect(await debt(starId), 2);
      });

      test('full exchange, walk-in: same, with a pool credit', () async {
        final order = await sell([line(starBottle, 3)], returned: {starId: 3});
        expect(order.status, 'completed');
        expect(order.completedAt, isNotNull);
        expect(await pool(), {starId: 3});
        expect(await db.orderCrateLinesDao.getForOrder(order.id), isEmpty);
      });

      test(
        'the pool row is store-stamped, attributed and seeded apart',
        () async {
          final order = await sell(
            [line(starBottle, 5)],
            customer: customerId,
            returned: {starId: 2},
          );
          final row = (await ledger(
            order.id,
          )).singleWhere((l) => l.customerId == null);
          expect(row.storeId, storeId);
          expect(row.performedBy, staffId);
          expect(row.movementType, 'adjusted');
          expect(row.reason, kCheckoutExchangeReason);
          expect(row.quantityDelta, 2);
          expect(
            row.id,
            UuidV7.deterministic(
              'crate_pool:${order.id}:$starId:checkout_exchange',
            ),
          );
          expect(await scalar(starId), 2);
          expect(
            await db.storeCrateBalancesDao.getBalance(
              storeId: storeId,
              manufacturerId: starId,
            ),
            2,
          );
          expect(await db.cratePoolDao.exchangeEmptiesForOrder(order.id), {
            starId: 2,
          });
        },
      );

      test(
        'the exchange row joins the sale outbox: held on v2, plain on v1',
        () async {
          final order = await sell(
            [line(starBottle, 5)],
            customer: customerId,
            returned: {starId: 2},
          );
          final rows = await db.select(db.syncQueue).get();
          final ledgerRows = rows.where(
            (q) => q.actionType.startsWith('crate_ledger'),
          );
          expect(ledgerRows, hasLength(2), reason: 'exchange + issued');
          for (final row in ledgerRows) {
            expect(row.heldByOrderId, v2 ? order.id : isNull);
          }
          expect(
            rows.where((q) => q.actionType.startsWith('manufacturers')),
            isEmpty,
            reason: 'the scalar is off the push set',
          );
          if (v2) {
            final envelope = rows.singleWhere(
              (q) => q.actionType == 'domain:pos_record_sale_v2',
            );
            expect(decodePayload(envelope)['p_status'], 'pending');
          }
        },
      );

      test('a fully covered v2 sale sends p_status completed', () async {
        await sell([line(starBottle, 5)], returned: {starId: 5});
        if (!v2) return;
        final envelope = (await db.select(db.syncQueue).get()).singleWhere(
          (q) => q.actionType == 'domain:pos_record_sale_v2',
        );
        expect(decodePayload(envelope)['p_status'], 'completed');
      });

      test('part exchange then Confirm: no key clash, pool ends up full, '
          'no debt', () async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 2},
        );
        expect(order.status, 'pending');
        final crateLine = (await db.orderCrateLinesDao.getForOrder(
          order.id,
        )).single;
        expect(crateLine.cratesTaken, 3);
        final issued = (await ledger(
          order.id,
        )).singleWhere((l) => l.movementType == 'issued');
        expect(issued.quantityDelta, 3);
        expect(await pool(), {starId: 2});
        expect(await debt(starId), 3);

        await confirm(order, [
          CrateReturnLine(
            manufacturerId: starId,
            takenCrates: 3,
            returnedCrates: 3,
            rateKobo: 50000,
            paidKobo: 0,
          ),
        ]);

        expect((await reload(order.id)).status, 'completed');
        expect(await pool(), {starId: 5});
        expect(await debt(starId), 0);
      });

      /// A walk-in Pending order as an older build wrote it (#656: Checkout no
      /// longer can): no customer, no crate line, the exchange row in the pool.
      Future<OrderData> legacyWalkInPending() async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 2},
        );
        await (db.update(db.orders)..where((o) => o.id.equals(order.id))).write(
          const OrdersCompanion(customerId: Value(null)),
        );
        await (db.delete(
          db.orderCrateLines,
        )..where((l) => l.orderId.equals(order.id))).go();
        return reload(order.id);
      }

      test('a legacy walk-in Pending order still confirms', () async {
        final order = await legacyWalkInPending();
        expect(order.status, 'pending');
        await confirm(order, [
          CrateReturnLine(
            manufacturerId: starId,
            takenCrates: 3,
            returnedCrates: 3,
            rateKobo: 0,
            paidKobo: 0,
          ),
        ]);
        expect((await reload(order.id)).status, 'completed');
        expect(await pool(), {starId: 5});
      });

      test('two brands, one cleared: only the other is on the order', () async {
        final order = await sell(
          [line(starBottle, 2), line(heroBottle, 3)],
          customer: customerId,
          returned: {starId: 2},
        );
        expect(order.status, 'pending');
        final lines = await db.orderCrateLinesDao.getForOrder(order.id);
        expect(lines.single.manufacturerId, heroId);
        expect(await debt(starId), 0);
        expect(await debt(heroId), 3);
      });

      test('a part-exchanged money-track sale settles at Confirm', () async {
        // 5 sold, 2 back, ₦1,500 full deposit on the 3 outstanding.
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 2},
          deposits: {starId: 150000},
        );
        final crateLine = (await db.orderCrateLinesDao.getForOrder(
          order.id,
        )).single;
        expect(crateLine.cratesTaken, 3);
        expect(crateLine.depositPaidKobo, 150000);
        expect(await debt(starId), 0, reason: 'money-track issues no debt');

        await confirm(order, [
          CrateReturnLine(
            manufacturerId: starId,
            takenCrates: 3,
            returnedCrates: 3,
            rateKobo: 50000,
            paidKobo: 150000,
          ),
        ]);

        expect(await pool(), {starId: 5});
        final held = await (db.select(
          db.walletTransactions,
        )..where((t) => t.orderId.equals(order.id))).get();
        final net = held
            .where(
              (t) => const [
                'crate_deposit',
                'crate_deposit_refunded',
                'crate_deposit_forfeited',
              ].contains(t.referenceType),
            )
            .fold<int>(0, (s, t) => s + t.signedAmountKobo);
        expect(net, 0, reason: 'the held deposit resolves to nothing');
      });

      test('all returned means no deposit legs', () async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 5},
        );
        final legs = await (db.select(
          db.walletTransactions,
        )..where((t) => t.orderId.equals(order.id))).get();
        expect(legs.where((t) => t.referenceType == 'crate_deposit'), isEmpty);
        expect(order.crateDepositPaidKobo, 0);
      });

      test('a deposit on a brand with none outstanding is refused', () async {
        await expectLater(
          sell(
            [line(starBottle, 5)],
            customer: customerId,
            returned: {starId: 5},
            deposits: {starId: 100000},
          ),
          throwsArgumentError,
        );
        expect(await pool(), isEmpty, reason: 'rolled back whole');
        expect(await db.select(db.orders).get(), isEmpty);
      });

      test(
        'a Pending refund of a part exchange puts everything back',
        () async {
          final order = await sell(
            [line(starBottle, 5)],
            customer: customerId,
            returned: {starId: 2},
          );

          await service.markAsCancelled(
            order.id,
            'Changed mind',
            staffId,
            gateContext: _granted,
          );

          expect(await pool(), {starId: 0});
          expect(await debt(starId), 0);
          expect(await scalar(starId), 0);
          expect(
            await db.storeCrateBalancesDao.getBalance(
              storeId: storeId,
              manufacturerId: starId,
            ),
            0,
          );
          final comp = (await ledger(
            order.id,
          )).singleWhere((l) => l.reason == kCheckoutExchangeReversalReason);
          expect(comp.storeId, storeId);
          expect(comp.customerId, isNull);
          expect(comp.quantityDelta, -2);
          expect(
            (await db.select(db.syncQueue).get()).where(
              (q) =>
                  q.actionType.startsWith('crate_ledger') &&
                  decodePayload(q)['id'] == comp.id,
            ),
            hasLength(1),
            reason: 'a refund compensation syncs',
          );
          expect(await db.cratePoolDao.exchangeEmptiesForOrder(order.id), {});
        },
      );

      test('a legacy walk-in Pending refund takes the empties back off',
          () async {
        final order = await legacyWalkInPending();
        await service.markAsCancelled(
          order.id,
          'Changed mind',
          staffId,
          gateContext: _granted,
        );
        expect(await pool(), {starId: 0});
      });

      test('a money-track Pending refund takes the empties back off', () async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 2},
          deposits: {starId: 150000},
        );
        await service.markAsCancelled(
          order.id,
          'Changed mind',
          staffId,
          gateContext: _granted,
        );
        expect(await pool(), {starId: 0});
      });

      test(
        'a refund the cloud rejects puts the exchange back, scalar included',
        () async {
          final order = await sell(
            [line(starBottle, 5)],
            customer: customerId,
            returned: {starId: 2},
          );
          await service.markAsCancelled(
            order.id,
            'Changed mind',
            staffId,
            gateContext: _granted,
          );
          expect(await scalar(starId), 0);
          final claim = (await db.select(
            db.syncQueue,
          ).get()).singleWhere((r) => r.actionType == kReversalClaimAction);

          expect(
            await db.ordersDao.undoRejectedReversal(
              reversalId: decodePayload(claim)['p_reversal_id'] as String,
              orderId: order.id,
            ),
            isTrue,
          );

          expect(await pool(), {starId: 2});
          expect(await scalar(starId), 2);
          expect(
            await db.storeCrateBalancesDao.getBalance(
              storeId: storeId,
              manufacturerId: starId,
            ),
            2,
          );
          expect(await debt(starId), 3);
          expect(await db.cratePoolDao.exchangeEmptiesForOrder(order.id), {
            starId: 2,
          });
        },
      );

      test('a rejected sale puts everything back and enqueues nothing', () async {
        final order = await sell(
          [line(starBottle, 5)],
          customer: customerId,
          returned: {starId: 2},
        );
        await db.delete(db.syncQueue).go();

        Future<void> reject() => db.ordersDao.reverseRejectedSaleLocal(
          orderId: order.id,
          items: [(productId: starBottle, storeId: storeId, quantity: 5)],
          staffId: staffId,
        );
        await reject();
        await reject();

        expect(await pool(), {starId: 0});
        expect(await debt(starId), 0);
        expect(await scalar(starId), 0);
        expect(await db.select(db.syncQueue).get(), isEmpty);
      });

      test('a rejected walk-in full exchange is undone too', () async {
        final order = await sell([line(starBottle, 3)], returned: {starId: 3});
        await db.ordersDao.reverseRejectedSaleLocal(
          orderId: order.id,
          items: [(productId: starBottle, storeId: storeId, quantity: 3)],
          staffId: staffId,
        );
        expect((await reload(order.id)).status, 'cancelled');
        expect(await pool(), {starId: 0});
      });

      test('quarter crates: 2.5 sold, 2.5 returned completes', () async {
        final order = await sell(
          [line(starBottle, 2.5)],
          customer: customerId,
          returned: {starId: 2.5},
        );
        expect(order.status, 'completed');
        expect(await pool(), {starId: 2.5});
      });

      test('a count off the quarter step is refused', () async {
        await expectLater(
          sell([line(starBottle, 5)], returned: {starId: 0.3}),
          throwsA(
            isA<CrateExchangeError>().having(
              (e) => e.refusal,
              'refusal',
              CrateExchangeRefusal.notQuarterStep,
            ),
          ),
        );
        expect(await db.select(db.orders).get(), isEmpty);
      });

      test('over-return and an unknown brand are refused at the write '
          'boundary', () async {
        await expectLater(
          sell([line(starBottle, 5)], returned: {starId: 6}),
          throwsA(isA<CrateExchangeError>()),
        );
        await expectLater(
          sell([line(starBottle, 5)], returned: {heroId: 1}),
          throwsA(isA<CrateExchangeError>()),
        );
        expect(await pool(), isEmpty);
      });

      test('a count on a business that does not track empties is refused', () async {
        await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
            .write(const BusinessesCompanion(tracksEmptyCrates: Value(false)));
        await expectLater(
          sell([line(starBottle, 5)], returned: {starId: 5}),
          throwsA(isA<CrateExchangeError>()),
        );
      });

      test('a bottle with no manufacturer does not block completion', () async {
        final loose = UuidV7.generate();
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: Value(loose),
                businessId: businessId,
                name: 'Loose',
                retailerPriceKobo: const Value(100000),
                unit: const Value('Bottle'),
                trackEmpties: const Value(true),
              ),
            );
        await db
            .into(db.inventory)
            .insert(
              InventoryCompanion.insert(
                businessId: businessId,
                productId: loose,
                storeId: storeId,
                quantity: const Value(10),
              ),
            );
        final order = await sell(
          [line(starBottle, 2), line(loose, 1)],
          returned: {starId: 2},
        );
        expect(order.status, 'completed');
      });
    });
  }
}

const _granted = GateContext(
  grantedKeys: {'sales.cancel'},
  roleRank: GateTier.manager,
  isReady: true,
);
