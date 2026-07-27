import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// #201 — the CLIENT half of the flag-gated money-parity fix (migration 0169).
///
/// The two v2 envelopes are the only writers of their money rows on the flagged
/// path: `OrdersDao.createOrder` writes NO local payment row when
/// `feature.domain_rpcs_v2.record_sale` is on, and `markCancelled` returns right
/// after enqueueing when `…cancel_order` is on. So whatever the RPC response
/// carries is what the device shows until the next pull, and every row 0169
/// writes must have a handler in `_applyDomainResponse`.
///
/// 0169 added two arrays to those envelopes, and these tests pin them:
///   • `payment_transactions` — the #175 three-way tender split (goods `sale` /
///     `crate_deposit` / `wallet_topup`). The pre-#201 singular
///     `payment_transaction` key carried ONE bundled row, so without the array
///     handler the deposit and top-up rows would exist only in the cloud.
///   • `cost_batches` — the cancel's restored cost layer (#170 #7c). Since #187 /
///     migration 0167 the recost replay no longer rebuilds `qty_remaining`, so
///     nothing else brings a cancelled sale's cost back on this path.
///
/// Driven through the real `SupabaseSyncService.applyServerResponse` — the same
/// entry the queue dispatch uses — so the response contract and the restore
/// wiring are exercised together.
void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  late String storeId;
  late String staffId;
  late String productId;
  late String orderId;

  final ts = DateTime.utc(2026, 7, 27, 12).toIso8601String();
  final cancelTs = DateTime.utc(2026, 7, 28, 9).toIso8601String();

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'user-1');
    sync = SupabaseSyncService(db, transport);

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
    productId = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star 60cl',
            retailerPriceKobo: const Value(100000),
          ),
        );
    orderId = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: businessId,
            orderNumber: 'ORD-201-1',
            totalAmountKobo: 230000,
            netAmountKobo: 230000,
            amountPaidKobo: const Value(250000),
            crateDepositPaidKobo: const Value(30000),
            paymentType: 'cash',
            status: 'completed',
            staffId: Value(staffId),
            storeId: Value(storeId),
          ),
        );
  });

  tearDown(() async {
    await transport.dispose();
    await db.close();
  });

  Map<String, dynamic> payRow({
    required String type,
    required int amountKobo,
    String? voidReason,
    String? createdAt,
  }) => {
    'id': UuidV7.generate(),
    'business_id': businessId,
    'store_id': storeId,
    'amount_kobo': amountKobo,
    'method': 'cash',
    'type': type,
    'order_id': orderId,
    'shipment_id': null,
    'expense_id': null,
    'wallet_txn_id': null,
    'delivery_id': null,
    'van_trip_id': null,
    'performed_by': staffId,
    'voided_at': null,
    'voided_by': null,
    'void_reason': voidReason,
    'created_at': createdAt ?? ts,
    'last_updated_at': createdAt ?? ts,
  };

  group('pos_record_sale_v2 response (#201 / 0169)', () {
    test(
      'the three-way tender split lands locally — goods sale, held deposit and '
      'overpayment, all store-stamped',
      () async {
        // A sale of 200000 goods + 30000 deposit, tendered 250000: the split is
        // sale 200000 / crate_deposit 30000 / wallet_topup 20000 (0169).
        final goods = payRow(type: 'sale', amountKobo: 200000);
        final deposit = payRow(type: 'crate_deposit', amountKobo: 30000);
        final topup = payRow(type: 'wallet_topup', amountKobo: 20000);

        await sync.applyServerResponse('pos_record_sale_v2', {
          'order': null,
          // The singular key is retained for envelope compatibility and carries
          // the GOODS row; the array carries the whole tender.
          'payment_transaction': goods,
          'payment_transactions': [goods, deposit, topup],
          'replayed': false,
        });

        final rows = await db.select(db.paymentTransactions).get();
        expect(
          rows,
          hasLength(3),
          reason:
              'all three legs must land; the pre-#201 singular key carried one '
              'bundled row and lost the deposit + top-up',
        );
        expect(
          {for (final r in rows) r.type: r.amountKobo},
          {'sale': 200000, 'crate_deposit': 30000, 'wallet_topup': 20000},
        );
        expect(
          rows.map((r) => r.storeId).toSet(),
          {storeId},
          reason: '#169 US 36 — every tender row is stamped with its store',
        );
        expect(
          rows.fold<int>(0, (s, r) => s + r.amountKobo),
          250000,
          reason: 'the legs sum to what was tendered — no cash created or lost',
        );
      },
    );

    test('a goods-only sale still lands exactly one `sale` row', () async {
      final goods = payRow(type: 'sale', amountKobo: 100000);

      await sync.applyServerResponse('pos_record_sale_v2', {
        'payment_transaction': goods,
        'payment_transactions': [goods],
        'replayed': false,
      });

      final rows = await db.select(db.paymentTransactions).get();
      expect(
        rows,
        hasLength(1),
        reason:
            'the singular and array handlers both see the same row and the '
            'upsert is idempotent — never a duplicate',
      );
      expect(rows.single.type, 'sale');
    });
  });

  group('pos_cancel_order response (#201 / 0169)', () {
    test(
      'compensating rows land in their own money families and no original is '
      'voided',
      () async {
        final goods = payRow(type: 'sale', amountKobo: 200000);
        final deposit = payRow(type: 'crate_deposit', amountKobo: 30000);
        final topup = payRow(type: 'wallet_topup', amountKobo: 20000);
        await sync.applyServerResponse('pos_record_sale_v2', {
          'payment_transactions': [goods, deposit, topup],
          'replayed': false,
        });

        // What 0169's cancel returns: the originals untouched, one dated
        // compensating row per reversible original, `voided_payments` empty.
        await sync.applyServerResponse('pos_cancel_order', {
          'voided_payments': const <Map<String, dynamic>>[],
          'refund_payments': [
            payRow(
              type: 'refund',
              amountKobo: 200000,
              voidReason: 'order_cancelled: changed mind',
              createdAt: cancelTs,
            ),
            payRow(
              type: 'crate_deposit',
              amountKobo: -30000,
              voidReason: 'order_cancelled: changed mind',
              createdAt: cancelTs,
            ),
            payRow(
              type: 'wallet_topup',
              amountKobo: -20000,
              voidReason: 'order_cancelled: changed mind',
              createdAt: cancelTs,
            ),
          ],
          'wallet_compensations': const <Map<String, dynamic>>[],
          'cost_batches': const <Map<String, dynamic>>[],
          'replayed': false,
        });

        final rows = await db.select(db.paymentTransactions).get();
        expect(rows, hasLength(6), reason: '3 originals + 3 compensating rows');
        expect(
          rows.every((r) => r.voidedAt == null),
          isTrue,
          reason:
              '#172 — the ledger is append-only; nothing is voided in place, so '
              'the reviewed sale day is never rewritten',
        );

        int netOf(String type) => rows
            .where((r) => r.type == type)
            .fold<int>(0, (s, r) => s + r.amountKobo);
        expect(
          netOf('crate_deposit'),
          0,
          reason: 'the held-deposit line nets to zero in its OWN family',
        );
        expect(
          netOf('wallet_topup'),
          0,
          reason: '"Debts collected" nets to zero in its OWN family',
        );
        expect(
          netOf('refund'),
          200000,
          reason:
              'only the GOODS leg becomes a refund — a deposit or top-up typed '
              'as `refund` would move Cash refunds for money that was never in '
              'Cash sales',
        );
      },
    );

    test('the cancelled sale\'s cost layer is restored from the response', () async {
      // 0169 appends one fresh FIFO layer per sale line at the per-unit COGS the
      // sale snapshotted. Nothing else restores it on this path since 0167.
      await sync.applyServerResponse('pos_cancel_order', {
        'refund_payments': const <Map<String, dynamic>>[],
        'cost_batches': [
          {
            'id': UuidV7.generate(),
            'business_id': businessId,
            'product_id': productId,
            'store_id': storeId,
            'qty_remaining': 2,
            'qty_original': 2,
            'cost_kobo': 60000,
            'received_at': cancelTs,
            'created_at': cancelTs,
            'last_updated_at': cancelTs,
          },
        ],
        'replayed': false,
      });

      final batches = await db.select(db.costBatches).get();
      expect(batches, hasLength(1));
      expect(batches.single.qtyRemaining, 2);
      expect(batches.single.qtyOriginal, 2);
      expect(
        batches.single.costKobo,
        60000,
        reason: 'the units come back COSTED at what the sale drew, not as '
            'phantom 0-cost stock',
      );
    });
  });
}
