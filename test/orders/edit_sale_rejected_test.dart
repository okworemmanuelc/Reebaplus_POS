// #732 (PR A) — a sale EDIT the cloud refuses (`pos_claim_sale_adjustment`
// raises P0001 because another phone changed the sale first) is withdrawn on
// this phone: stock AND the FIFO cost layers end exactly as before the edit.
// The plus lines drew units from EXISTING layers; those units are put back
// (the layers are never deleted), and the restore layers the minus lines made
// are withdrawn. The person sees one plain message.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

const _claimRpc = 'pos_claim_sale_adjustment';

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  late String storeId;
  late String staffId;
  late String customerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'auth-1');
    sync = SupabaseSyncService(db, transport);
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Manager', pin: '0'));
    customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
  });

  tearDown(() => db.close());

  /// A product with two cost layers: 3 units at 500 then 100 units at 600.
  Future<String> product(String name) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: name,
        retailerPriceKobo: const Value(100000),
        buyingPriceKobo: const Value(50000),
        unit: const Value('Piece')));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: id,
        storeId: storeId,
        quantity: const Value(103)));
    await db.costBatchesDao.recordInflowBatch(
        productId: id,
        storeId: storeId,
        quantity: 3,
        costKobo: 50000,
        receivedAt: DateTime(2026, 1, 1));
    await db.costBatchesDao.recordInflowBatch(
        productId: id,
        storeId: storeId,
        quantity: 100,
        costKobo: 60000,
        receivedAt: DateTime(2026, 2, 1));
    return id;
  }

  /// A completed, fully paid sale of [lines] (product -> qty).
  Future<String> completedSale(Map<String, int> lines) async {
    final total = lines.values.fold<int>(0, (a, q) => a + q * 100000);
    final id = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: Value(total),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(storeId),
      ),
      items: [
        for (final e in lines.entries)
          OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: 'placeholder',
            productId: Value(e.key),
            storeId: storeId,
            quantity: e.value.toDouble(),
            unitPriceKobo: 100000,
            totalKobo: e.value * 100000,
          ),
      ],
      customerId: customerId,
      amountPaidKobo: total,
      totalAmountKobo: total,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
    );
    await db.ordersDao.markCompleted(id, staffId);
    return id;
  }

  Future<String> lineOf(String orderId, String productId) async =>
      (await (db.select(db.orderItems)
                ..where((i) =>
                    i.orderId.equals(orderId) & i.productId.equals(productId)))
              .getSingle())
          .id;

  Future<Map<String, double>> layers() async => {
        for (final b in await db.select(db.costBatches).get())
          b.id: b.qtyRemaining,
      };

  Future<Map<String, double>> stock() async => {
        for (final r in await db.select(db.inventory).get())
          r.productId: r.quantity,
      };

  Future<Map<String, int?>> scalarCost() async => {
        for (final p in await db.select(db.products).get())
          p.id: p.buyingPriceKobo,
      };

  Future<SyncQueueData> claimRow() async => (await (db.select(db.syncQueue)
        ..where((t) => t.actionType.equals(kAdjustmentClaimAction)))
      .getSingle());

  /// Lower [lowered] from 4 to 2 and add 3 of [added]: the plus line draws the
  /// last unit of [added]'s first layer and 2 of its second.
  Future<String> mixedEdit(String orderId, String lowered, String added) async {
    final out = await db.ordersDao.editCompletedSale(
      orderId: orderId,
      newQtyByLineId: {await lineOf(orderId, lowered): 2},
      addedLines: [EditAddedLine(productId: added, quantity: 3)],
      reason: 'customer changed order',
      staffId: staffId,
      deviceTag: 'TESTAB',
      refundMethod: 'cash',
    );
    return out.adjustmentOrderId;
  }

  Future<void> refuseClaim() async {
    transport.failRpc(
      _claimRpc,
      const PostgrestException(
        message: 'adjustment_exceeds_returnable',
        code: 'P0001',
      ),
    );
    await sync.pushDomainItemsForTesting([await claimRow()], businessId, 'auth-1');
  }

  test('the claim carries the drawn units in its phone-only notes, and the '
      'notes never reach the cloud', () async {
    final a = await product('Rice');
    final b = await product('Beans');
    final id = await completedSale({a: 2, b: 4});
    final batchA1 = (await (db.select(db.costBatches)
              ..where((t) => t.productId.equals(a) & t.costKobo.equals(50000)))
            .getSingle())
        .id;
    await mixedEdit(id, b, a);

    final local =
        decodePayload(await claimRow())[kLocalEnvelopeKey] as Map<String, dynamic>;
    expect(local['edit'], isTrue);
    final draws = (local['cost_draws'] as Map).cast<String, num>();
    expect(draws[batchA1], 1, reason: 'the last unit of the old layer');
    expect(draws.values.fold<num>(0, (s, v) => s + v), 3);

    transport.stubRpc(_claimRpc, (_) => {'replayed': false});
    await sync.pushDomainItemsForTesting([await claimRow()], businessId, 'auth-1');
    final sent = transport.rpcCalls.singleWhere((c) => c.name == _claimRpc);
    expect(sent.params.containsKey(kLocalEnvelopeKey), isFalse);
    expect(sent.params['p_lines'], isNotEmpty);
  });

  for (final synced in [true, false]) {
    test('a refused edit (plus + minus lines) leaves stock and cost layers '
        'exactly as before (sale ${synced ? 'already uploaded' : 'still queued'})',
        () async {
      final a = await product('Rice');
      final b = await product('Beans');
      final id = await completedSale({a: 2, b: 4});
      // Uploaded sale: the edit's layer upserts are fresh (held) rows.
      // Queued sale: they coalesce into the sale's own pending upserts.
      if (synced) await db.delete(db.syncQueue).go();

      final layersBefore = await layers();
      final stockBefore = await stock();
      final costBefore = await scalarCost();

      final adjustmentId = await mixedEdit(id, b, a);
      expect(await layers(), isNot(layersBefore), reason: 'the edit moved layers');
      expect((await stock())[a], stockBefore[a]! - 3);
      expect((await stock())[b], stockBefore[b]! + 2);

      await refuseClaim();

      expect(await layers(), layersBefore,
          reason: 'drawn units put back, restore layers withdrawn');
      expect(await stock(), stockBefore);
      expect(await scalarCost(), costBefore);
      expect(await db.ordersDao.adjustmentsOf(id), isEmpty);
      expect(
          await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(adjustmentId)))
              .get(),
          isEmpty);

      // What will upload for the layers equals what they hold now.
      final queue = await db.select(db.syncQueue).get();
      for (final q in queue.where((q) => q.actionType == 'cost_batches:upsert')) {
        final p = decodePayload(q);
        expect((p['qty_remaining'] as num).toDouble(), layersBefore[p['id']],
            reason: 'queued layer ${p['id']}');
      }
      if (synced) {
        expect(queue.where((q) => q.actionType == 'cost_batches:upsert'), isEmpty,
            reason: 'the cloud never saw the draw: nothing to re-send');
      }

      // The person sees the plain message, in Sync Issues and as an alert.
      final orphan = (await db.select(db.syncQueueOrphans).get())
          .singleWhere((o) => o.actionType == kAdjustmentClaimAction);
      expect(orphan.reason, contains(kEditRejectedMessage));
      final alerts = await db.select(db.notifications).get();
      final mine = alerts.singleWhere((n) => n.recipientUserId == staffId);
      expect(mine.message, contains(kEditRejectedMessage));
      expect(mine.linkedRecordId, id);
    });
  }

  test('a refused part return still reads as a return, not an edit', () async {
    final a = await product('Rice');
    final id = await completedSale({a: 4});
    await db.ordersDao.returnPartOfSale(
      orderId: id,
      qtyByLineId: {await lineOf(id, a): 1},
      reason: 'brought some back',
      staffId: staffId,
      deviceTag: 'TESTAB',
      refundMethod: 'cash',
    );
    final layersBefore = await db.select(db.costBatches).get();
    expect(jsonDecode((await claimRow()).payload)[kLocalEnvelopeKey], isNull);
    await refuseClaim();
    final orphan = (await db.select(db.syncQueueOrphans).get())
        .singleWhere((o) => o.actionType == kAdjustmentClaimAction);
    expect(orphan.reason, isNot(contains(kEditRejectedMessage)));
    expect((await db.select(db.costBatches).get()).length,
        layersBefore.length - 1, reason: 'only the restore layer goes');
  });
}
