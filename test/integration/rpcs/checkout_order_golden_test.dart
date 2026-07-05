@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../golden/golden_scenario.dart';
import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Golden-Scenario Suite — the SQL `checkout_order` RPC side (ADR 0009, #43).
///
/// Runs the SAME shared fixtures (cash/credit + crate, test/golden/fixtures/*.json)
/// as the Dart DAO runner (test/golden/dart_dao_golden_test.dart), but against the
/// server-authoritative `checkout_order` RPC (0135 → 0136 credit → 0137 crate) on
/// real dev Supabase. Any drift between the two implementations of the money +
/// crate rule fails the build — the anti-divergence guarantee behind "two
/// implementations, one contract".
///
/// Tier-2: hits live Supabase, auto-skipped when the env vars are absent. Seeds
/// via the service-role adminClient; invokes the RPC via the signed-in userClient
/// (the RPC reads auth.uid() for the tenant + permission guards). Every row it
/// creates is torn down by id (children before parents; FKs into orders: order_
/// items CASCADE, payment/stock NO ACTION → delete those first).
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

void main() {
  late TestClients clients;
  late String businessId;

  // Per-test ids, torn down after each scenario.
  String? storeId;
  final productIds = <String>[];
  final inventoryIds = <String>[];
  final batchIds = <String>[];
  final orderIds = <String>[];
  final customerIds = <String>[];
  final walletIds = <String>[];
  final manufacturerIds = <String>[];

  // The shared env business's original crate settings — crate scenarios flip the
  // business to crate-eligible for the duration of the sale, then tearDown
  // restores these so the run leaves the dev business exactly as it found it.
  String? origBizType;
  bool? origBizTracks;

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    businessId = clients.env.businessId;
    final biz = await clients.adminClient
        .from('businesses')
        .select('type, tracks_empty_crates')
        .eq('id', businessId)
        .single();
    origBizType = biz['type'] as String?;
    origBizTracks = biz['tracks_empty_crates'] as bool?;
  });

  tearDown(() async {
    if (_skipReason != null) return;
    // Children before parents. wallet/payment/stock FK into orders is NO ACTION,
    // so they must go before the order; order_items CASCADE with the order. The
    // wallet legs (incl. the seeded opening credit) go by customer. Crate rows
    // (order_crate_lines + the 'issued' crate_ledger) reference the order too, so
    // they go before it; customer_crate_balances goes with the customer.
    for (final id in customerIds) {
      await clients.adminClient.from('wallet_transactions').delete().eq('customer_id', id);
      await clients.adminClient.from('customer_crate_balances').delete().eq('customer_id', id);
    }
    for (final id in orderIds) {
      await clients.adminClient.from('crate_ledger').delete().eq('reference_order_id', id);
      await clients.adminClient.from('order_crate_lines').delete().eq('order_id', id);
      await clients.adminClient.from('stock_transactions').delete().eq('order_id', id);
      await clients.adminClient.from('payment_transactions').delete().eq('order_id', id);
      await clients.adminClient.from('orders').delete().eq('id', id);
    }
    for (final id in walletIds) {
      await clients.adminClient.from('customer_wallets').delete().eq('id', id);
    }
    for (final id in customerIds) {
      await clients.adminClient.from('customers').delete().eq('id', id);
    }
    for (final id in batchIds) {
      await clients.adminClient.from('cost_batches').delete().eq('id', id);
    }
    for (final id in inventoryIds) {
      await clients.adminClient.from('inventory').delete().eq('id', id);
    }
    for (final id in productIds) {
      await clients.adminClient.from('products').delete().eq('id', id);
    }
    // products FK manufacturer_id → manufacturers, so drop manufacturers after.
    for (final id in manufacturerIds) {
      await clients.adminClient.from('manufacturers').delete().eq('id', id);
    }
    if (storeId != null) {
      await clients.adminClient.from('stores').delete().eq('id', storeId!);
    }
    // Restore the business's crate settings a crate scenario may have flipped.
    await clients.adminClient.from('businesses').update({
      'type': origBizType,
      'tracks_empty_crates': origBizTracks,
    }).eq('id', businessId);
    storeId = null;
    productIds.clear();
    inventoryIds.clear();
    batchIds.clear();
    orderIds.clear();
    customerIds.clear();
    walletIds.clear();
    manufacturerIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  final scenarios = [...loadCashSaleScenarios(), ...loadCrateSaleScenarios()];
  for (final scenario in scenarios) {
    test('golden (checkout_order rpc): ${scenario.name}', () async {
      final admin = clients.adminClient;

      // ── Seed the input state ────────────────────────────────────────────────
      final store = UuidV7.generate();
      storeId = store;
      await admin.from('stores').insert({
        'id': store,
        'business_id': businessId,
        'name': 'Golden Store',
      });

      // Slice 4 (#45): a crate scenario flips the (shared) business to
      // crate-eligible + the empties opt-in for this sale (tearDown restores it),
      // and registers the manufacturers whose deposit rates the sale snapshots.
      if (scenario.businessType != null) {
        await admin.from('businesses').update({
          'type': scenario.businessType,
          'tracks_empty_crates': scenario.tracksEmptyCrates,
        }).eq('id', businessId);
      }
      final manufacturerIdByKey = <String, String>{};
      for (final m in scenario.manufacturers) {
        final id = UuidV7.generate();
        manufacturerIdByKey[m.key] = id;
        manufacturerIds.add(id);
        await admin.from('manufacturers').insert({
          'id': id,
          'business_id': businessId,
          'name': m.name,
          'deposit_amount_kobo': m.depositRateKobo,
        });
      }

      final productIdByKey = <String, String>{};
      for (final p in scenario.products) {
        final id = UuidV7.generate();
        productIdByKey[p.key] = id;
        productIds.add(id);
        // A crate-eligible product (manufacturerKey set) is a returnable bottle
        // with empties tracking on; everything else is a plain product.
        final crateEligible = p.manufacturerKey != null;
        await admin.from('products').insert({
          'id': id,
          'business_id': businessId,
          'name': p.name,
          'retailer_price_kobo': p.unitPriceKobo,
          'buying_price_kobo': p.scalarCostKobo,
          if (crateEligible) 'unit': 'Bottle',
          if (crateEligible) 'track_empties': true,
          if (crateEligible)
            'manufacturer_id': manufacturerIdByKey[p.manufacturerKey],
        });
      }
      for (final inv in scenario.inventory) {
        final id = UuidV7.generate();
        inventoryIds.add(id);
        await admin.from('inventory').insert({
          'id': id,
          'business_id': businessId,
          'product_id': productIdByKey[inv.productKey],
          'store_id': store,
          'quantity': inv.quantity,
        });
      }
      // batchId → (productKey, receivedAt) for the remainder assertion.
      final seededBatches = <(String, String, String)>[];
      for (final b in scenario.batches) {
        final id = UuidV7.generate();
        batchIds.add(id);
        await admin.from('cost_batches').insert({
          'id': id,
          'business_id': businessId,
          'product_id': productIdByKey[b.productKey],
          'store_id': store,
          'qty_remaining': b.qty,
          'qty_original': b.qty,
          'cost_kobo': b.costKobo,
          'received_at': b.receivedAtUtc.toIso8601String(),
        });
        seededBatches.add((id, b.productKey, b.receivedAt));
      }

      // Slice 3 (#44): a registered customer + wallet, seeded with any opening
      // balance as one topup_cash credit BEFORE the sale. The opening leg has no
      // order_id, so the per-order leg collection below excludes it.
      String? customerId;
      if (scenario.customer != null) {
        customerId = UuidV7.generate();
        final walletId = UuidV7.generate();
        customerIds.add(customerId);
        walletIds.add(walletId);
        await admin.from('customers').insert({
          'id': customerId,
          'business_id': businessId,
          'name': 'Credit Customer',
          'wallet_limit_kobo': scenario.customer!.debtLimitKobo,
        });
        await admin.from('customer_wallets').insert({
          'id': walletId,
          'business_id': businessId,
          'customer_id': customerId,
        });
        if (scenario.customer!.openingBalanceKobo != 0) {
          await admin.from('wallet_transactions').insert({
            'id': UuidV7.generate(),
            'business_id': businessId,
            'wallet_id': walletId,
            'customer_id': customerId,
            'type': 'credit',
            'amount_kobo': scenario.customer!.openingBalanceKobo,
            'signed_amount_kobo': scenario.customer!.openingBalanceKobo,
            'reference_type': 'topup_cash',
          });
        }
      }

      // ── Perform the checkout via the server-authoritative RPC ──────────────
      final orderId = UuidV7.generate();
      orderIds.add(orderId);
      final gross = scenario.checkout.items.fold<int>(
          0,
          (s, l) =>
              s + scenario.product(l.productKey).unitPriceKobo * l.quantity);
      final net = gross - scenario.checkout.discountKobo;
      // Walk-in cash/transfer pays the net; a credit/wallet sale passes exactly
      // what the fixture tendered (the RPC clamps + routes it).
      final amountPaid =
          customerId != null ? scenario.checkout.amountPaidKobo : net;

      final params = <String, dynamic>{
        'p_business_id': businessId,
        'p_order_id': orderId,
        'p_store_id': store,
        'p_items': [
          for (final l in scenario.checkout.items)
            {
              'product_id': productIdByKey[l.productKey],
              'quantity': l.quantity,
              'unit_price_kobo': scenario.product(l.productKey).unitPriceKobo,
            }
        ],
        'p_payment_method': scenario.checkout.paymentMethod,
        'p_amount_paid_kobo': amountPaid,
        'p_discount_kobo': scenario.checkout.discountKobo,
        'p_customer_id': customerId,
      };

      // A rejection scenario (Slice 3, #55): the RPC must refuse — its debt-limit
      // guard raises (P0001) BEFORE any write — and persist nothing. Assert the
      // raise carries the expected token and that no order row exists, then stop:
      // there are no result rows to compare against a golden outcome.
      if (scenario.expectRejection != null) {
        await expectLater(
          clients.userClient.rpc('checkout_order', params: params),
          throwsA(predicate(
              (Object e) => e.toString().contains(scenario.expectRejection!))),
        );
        final leftover = await admin
            .from('orders')
            .select('id')
            .eq('id', orderId)
            .maybeSingle();
        expect(leftover, isNull,
            reason: '${scenario.name}: a rejected sale writes no order');
        return;
      }

      await clients.userClient.rpc('checkout_order', params: params);

      // ── Collect the resulting rows in fixture terms ────────────────────────
      final keyByProductId = {
        for (final e in productIdByKey.entries) e.value: e.key
      };

      final orderRow = await admin
          .from('orders')
          .select(
              'order_number, status, payment_type, total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo, completed_at')
          .eq('id', orderId)
          .single();

      final itemRows = await admin
          .from('order_items')
          .select('product_id, quantity, unit_price_kobo, total_kobo, buying_price_kobo')
          .eq('order_id', orderId);

      final paymentRow = await admin
          .from('payment_transactions')
          .select('method, amount_kobo')
          .eq('order_id', orderId)
          .eq('type', 'sale')
          .maybeSingle();

      // Wallet legs THIS sale posted (order_id == this order) + the customer's
      // derived spendable balance (SUM(signed) excluding the crate-deposit family).
      const crateDepositRefs = {
        'crate_deposit',
        'crate_deposit_refunded',
        'crate_deposit_forfeited',
      };
      final walletLegs = <ActualWalletLeg>[];
      int? customerBalanceAfter;
      if (customerId != null) {
        final legRows = await admin
            .from('wallet_transactions')
            .select('reference_type, signed_amount_kobo')
            .eq('order_id', orderId);
        for (final l in legRows) {
          walletLegs.add(ActualWalletLeg(
            referenceType: l['reference_type'] as String,
            signedAmountKobo: (l['signed_amount_kobo'] as num).toInt(),
          ));
        }
        final allLegs = await admin
            .from('wallet_transactions')
            .select('reference_type, signed_amount_kobo')
            .eq('customer_id', customerId);
        customerBalanceAfter = allLegs
            .where((l) => !crateDepositRefs.contains(l['reference_type']))
            .fold<int>(
                0, (s, l) => s + (l['signed_amount_kobo'] as num).toInt());
      }

      // Crate rows THIS sale posted (Slice 4, #45), keyed by manufacturer.
      final keyByManufacturerId = {
        for (final e in manufacturerIdByKey.entries) e.value: e.key
      };
      final crateLines = <String, ActualCrateLine>{};
      final crateLedgerIssued = <String, int>{};
      final crateBalances = <String, int>{};
      if (customerId != null && manufacturerIdByKey.isNotEmpty) {
        final lineRows = await admin
            .from('order_crate_lines')
            .select('manufacturer_id, crates_taken, deposit_rate_kobo, deposit_paid_kobo')
            .eq('order_id', orderId);
        for (final l in lineRows) {
          crateLines[keyByManufacturerId[l['manufacturer_id']]!] =
              ActualCrateLine(
            cratesTaken: (l['crates_taken'] as num).toInt(),
            depositRateKobo: (l['deposit_rate_kobo'] as num).toInt(),
            depositPaidKobo: (l['deposit_paid_kobo'] as num).toInt(),
          );
        }
        final ledgerRows = await admin
            .from('crate_ledger')
            .select('manufacturer_id, quantity_delta')
            .eq('reference_order_id', orderId)
            .eq('movement_type', 'issued');
        for (final c in ledgerRows) {
          final key = keyByManufacturerId[c['manufacturer_id']]!;
          crateLedgerIssued[key] =
              (crateLedgerIssued[key] ?? 0) + (c['quantity_delta'] as num).toInt();
        }
        final balRows = await admin
            .from('customer_crate_balances')
            .select('manufacturer_id, balance')
            .eq('customer_id', customerId);
        for (final b in balRows) {
          crateBalances[keyByManufacturerId[b['manufacturer_id']]!] =
              (b['balance'] as num).toInt();
        }
      }

      final batchRemaining = <String, int>{};
      for (final (id, productKey, receivedAt) in seededBatches) {
        final row = await admin
            .from('cost_batches')
            .select('qty_remaining')
            .eq('id', id)
            .single();
        batchRemaining['$productKey|$receivedAt'] =
            (row['qty_remaining'] as num).toInt();
      }

      final inventoryAfter = <String, int>{};
      final scalarCost = <String, int>{};
      for (final entry in productIdByKey.entries) {
        final invRow = await admin
            .from('inventory')
            .select('quantity')
            .eq('product_id', entry.value)
            .eq('store_id', store)
            .maybeSingle();
        if (invRow != null) {
          inventoryAfter[entry.key] = (invRow['quantity'] as num).toInt();
        }
        final prodRow = await admin
            .from('products')
            .select('buying_price_kobo')
            .eq('id', entry.value)
            .single();
        scalarCost[entry.key] = (prodRow['buying_price_kobo'] as num).toInt();
      }

      final outcome = CheckoutOutcome(
        orderNumber: orderRow['order_number'] as String,
        order: ActualOrder(
          status: orderRow['status'] as String,
          paymentType: orderRow['payment_type'] as String,
          totalAmountKobo: (orderRow['total_amount_kobo'] as num).toInt(),
          discountKobo: (orderRow['discount_kobo'] as num).toInt(),
          netAmountKobo: (orderRow['net_amount_kobo'] as num).toInt(),
          amountPaidKobo: (orderRow['amount_paid_kobo'] as num).toInt(),
          completedAtNull: orderRow['completed_at'] == null,
        ),
        items: [
          for (final i in itemRows)
            ActualItem(
              productKey: keyByProductId[i['product_id']]!,
              quantity: (i['quantity'] as num).toInt(),
              unitPriceKobo: (i['unit_price_kobo'] as num).toInt(),
              totalKobo: (i['total_kobo'] as num).toInt(),
              buyingPriceKobo: (i['buying_price_kobo'] as num).toInt(),
            ),
        ],
        batchRemaining: batchRemaining,
        inventoryAfter: inventoryAfter,
        productScalarCost: scalarCost,
        payment: paymentRow == null
            ? null
            : ActualPayment(
                method: paymentRow['method'] as String,
                amountKobo: (paymentRow['amount_kobo'] as num).toInt(),
              ),
        walletLegs: walletLegs,
        customerBalanceAfter: customerBalanceAfter,
        crateLines: crateLines,
        crateLedgerIssued: crateLedgerIssued,
        crateBalances: crateBalances,
      );

      expectGolden(scenario, outcome, orderNumberScheme: webOrderNumberScheme);
    },
        // The clamp keys off the CALLER's role cap, and 0135 short-circuits the
        // CEO slug to 100 — so it can't bite for this Tier-2 identity (the
        // business CEO). The clamp rule is pinned on the Dart arm; skip it here
        // rather than assert an un-clampable caller.
        skip: _skipReason ??
            (scenario.maxDiscountPercent != null
                ? 'discount clamp needs a non-CEO caller; pinned on the Dart arm'
                : null));
  }
}
