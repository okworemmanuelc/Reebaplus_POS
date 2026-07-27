import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart'
    show SaleSyncException;
import 'package:reebaplus_pos/core/utils/order_number.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_flusher.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// The Order module's **command surface** (ADR 0004): the three lifecycle
/// writes — **Checkout** (settle the sale, recognise revenue), **Confirm** (the
/// ceremonial `pending`→`completed` flip), and **Cancel** (reverse a settled
/// sale) — plus the reject → compensate reversal that pairs with Checkout.
///
/// This is where the order invariants live. It orchestrates and enforces; the
/// atomic DB work is delegated to `OrdersDao`. Cloud push goes through the
/// narrow [SaleFlusher] seam, so the flush → reject → compensate path is
/// testable without a live Sync Engine.
class OrderCommands {
  final AppDatabase _db;
  final SaleFlusher _flusher;
  final SecureStorageService? _secureStorage;
  late final OrdersDao _ordersDao = _db.ordersDao;

  OrderCommands(this._db, this._flusher, [this._secureStorage]);

  /// Resolves this device's opaque id for the order-number tag (§30.8.1).
  /// `_secureStorage` is always injected in production (see
  /// `orderServiceProvider`); the constant fallback only ever applies to tests
  /// that construct the module without it.
  Future<String> _orderDeviceTag() async {
    final deviceId =
        await _secureStorage?.getOrCreateDeviceId() ?? 'unconfigured-device';
    return deviceOrderTag(deviceId);
  }

  /// **Checkout** — build an order from a UI cart and persist it atomically,
  /// recognising revenue (the Order is born `pending`).
  ///
  /// Returns the human-readable order number (e.g. `ORD-000042`) — the
  /// checkout/receipt code displays this to the user.
  Future<String> checkout({
    required String? customerId,
    required List<Map<String, dynamic>> cart,
    required int totalAmountKobo,
    required int amountPaidKobo,
    required String paymentType,
    String? staffId,
    String? storeId,
    int crateDepositPaidKobo = 0,
    int discountKobo = 0,
    String paymentSubType = 'cash',
    int walletBalanceKobo = 0,
    // §13.4 — deposit actually paid per manufacturer/brand (Ring 3). Empty until
    // the checkout per-brand capture is wired; createOrder then treats every
    // crate brand as "no deposit" (crate-track).
    Map<String, int> crateDepositPaidByManufacturer = const {},
  }) async {
    if (staffId == null || staffId.isEmpty) {
      throw ArgumentError('staffId is required');
    }
    if (storeId == null || storeId.isEmpty) {
      throw ArgumentError('storeId is required');
    }
    if (cart.isEmpty) {
      throw ArgumentError('cart is empty');
    }
    final orderId = UuidV7.generate();
    final orderNumber = await _ordersDao.generateOrderNumber(
      await _orderDeviceTag(),
    );

    final dbPaymentType = _resolvePaymentType(
      paymentSubType: paymentSubType,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
      walletBalanceKobo: walletBalanceKobo,
    );
    final walletDebitKobo = _resolveWalletDebit(
      dbPaymentType: dbPaymentType,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
    );
    if (walletDebitKobo > 0 && (customerId == null || customerId.isEmpty)) {
      throw ArgumentError(
        'Wallet/credit/partial payments require a customerId',
      );
    }

    final items = _buildOrderItems(
      cart: cart,
      orderId: orderId,
      storeId: storeId,
    );

    final orderCompanion = OrdersCompanion.insert(
      id: Value(orderId),
      businessId: _ordersDao.requireBusinessId(),
      orderNumber: orderNumber,
      customerId: Value(customerId),
      totalAmountKobo: totalAmountKobo,
      // [totalAmountKobo] is the payable the customer owes, already net of
      // per-line discounts (the cart subtracts them before checkout). The
      // server's pos_record_sale_v2 RPC recomputes the gross from p_items and
      // derives net = gross − discount + crate_deposit, so we forward
      // [discountKobo] as the order's discount but must NOT re-subtract it from
      // the local net here — that would double-count. The server's response
      // overwrites these mirror values on success (_applyDomainResponse).
      discountKobo: Value(discountKobo),
      netAmountKobo: totalAmountKobo,
      amountPaidKobo: Value(amountPaidKobo),
      paymentType: dbPaymentType,
      // §19.5 lifecycle: a completed checkout lands the order in Pending
      // (already settled — received, or charged through the wallet, §14.3).
      // Confirm (OrdersDao.markCompleted) flips it to 'completed' and stamps
      // completedAt — for crate businesses that's after the Empty-Crates modal.
      // Revenue is recognized here at checkout, not at Confirm; the wallet legs
      // are already booked regardless of status. The v2 RPC forwards this status
      // via p_status, so both sync paths agree.
      status: 'pending',
      staffId: Value(staffId),
      storeId: Value(storeId),
      crateDepositPaidKobo: Value(crateDepositPaidKobo),
    );

    await _ordersDao.createOrder(
      order: orderCompanion,
      items: items,
      customerId: customerId,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: _resolvePaymentMethod(paymentSubType),
      crateDepositPaidByManufacturer: crateDepositPaidByManufacturer,
    );

    // Surface server-side errors (insufficient_stock from a concurrent
    // device, FK / unique violations) BEFORE the receipt prints. flushSale
    // is a no-op when offline, when the queue row is absent (already
    // drained by background push), or when the sale was enqueued under
    // the legacy multi-row path. On permanent failure we compensate
    // locally — cancel the order, refund the inventory cache — so the
    // device's view stays consistent with the cloud's "this sale never
    // happened".
    if (_flusher.canFlush) {
      try {
        await _flusher.flushSale(orderId);
      } on SaleSyncException catch (e) {
        debugPrint('[OrderCommands] Sale rejected by server: $e');
        await _compensateRejectedSale(orderId, items, staffId);
        rethrow;
      } catch (e) {
        // Transient error — the queue row stays pending and the
        // background drain will retry. Don't block the receipt.
        debugPrint('[OrderCommands] flushSale transient: $e');
      }
    }

    await _runPostCheckoutSideEffects(
      orderId: orderId,
      orderNumber: orderNumber,
      cart: cart,
      customerId: customerId,
      staffId: staffId,
      storeId: storeId,
    );

    return orderNumber;
  }

  /// **Confirm** — settle the counted-back empties, then flip `pending`→
  /// `completed` (stamps `completedAt`). Creates no revenue.
  ///
  /// Crate settlement runs *before* the status flip — the same order the UI
  /// used to run them in (the modal wrote crate returns, then `markCompleted`
  /// ran separately). A crate-settle failure aborts before the flip, exactly as
  /// before. [crateReturns] is empty for a non-crate order (straight flip).
  ///
  /// **ONE transaction (#188).** Settlement and the flip commit together or not
  /// at all, and the order-status re-read happens INSIDE that transaction. They
  /// used to be two independent transactions, so a flip that failed after the
  /// settlement committed (`_enqueueFullOrder` throws on missing tenant context)
  /// left the order `pending` with its deposit already settled — and the next
  /// Confirm on the SAME device settled it a second time. Now the settlement
  /// rolls back with the flip and the next Confirm starts from a clean slate.
  Future<void> confirm(
    String orderId,
    String staffId, {
    String? customerId,
    String? storeId,
    List<CrateReturnLine> crateReturns = const [],
    bool refundAsCash = false,
  }) async {
    await _db.transaction(() async {
      // Idempotency guard 1 of 2, #171 — the CONVERGED double-Confirm: a prior
      // Confirm (this device or a peer whose `completed` has since been pulled)
      // already settled this order. Re-read INSIDE the transaction and skip both
      // halves. It cannot close the both-devices-offline case — each reads
      // `pending` — which is what guard 2 (the per-(order, manufacturer) claim in
      // [_settleCrateReturns]) and the deterministic leg ids are for.
      final order = await _ordersDao.findById(orderId);
      if (order == null || order.status != 'pending') return;

      await _settleCrateReturns(
        orderId: orderId,
        staffId: staffId,
        customerId: customerId,
        storeId: storeId,
        crateReturns: crateReturns,
        refundAsCash: refundAsCash,
      );
      await _ordersDao.markCompleted(orderId, staffId);
    });
  }

  /// The crate-return settlement half of **Confirm**, moved off the UI
  /// (`CrateReturnModal` used to perform these writes; it now only collects the
  /// counts). Physical empties come back regardless; money-track brands settle
  /// the held deposit (refund / forfeit / shortfall), crate-track brands net the
  /// issued balance. Walk-ins record only physical stock. Preserves the modal's
  /// exact per-row logic.
  ///
  /// Runs INSIDE [confirm]'s single transaction, which also holds the
  /// order-status re-read and the status flip (#188) — so a settlement that
  /// half-succeeds leaves nothing behind.
  Future<void> _settleCrateReturns({
    required String orderId,
    required String staffId,
    required String? customerId,
    required String? storeId,
    required List<CrateReturnLine> crateReturns,
    required bool refundAsCash,
  }) async {
    if (crateReturns.isEmpty) return;

    // Walk-in customer: just record physical stock returns (no wallet/ledger).
    // There is no `order_crate_lines` row to claim for a walk-in (createOrder
    // writes them only for a registered customer), so the pool credit's
    // deterministic id — keyed on (order, manufacturer) via [orderId] — is what
    // keeps a two-device offline Confirm from crediting the pool twice.
    if (customerId == null || customerId.isEmpty) {
      for (final line in crateReturns) {
        if (line.manufacturerId.isEmpty) continue;
        await _db.inventoryDao.addEmptyCrates(
          line.manufacturerId,
          line.returnedCrates,
          storeId: storeId,
          orderId: orderId,
        );
      }
      return;
    }

    for (final line in crateReturns) {
      if (line.manufacturerId.isEmpty) continue;
      // Nothing to settle: a crate-track brand with no crates counted back
      // writes no row at all. Claiming it would burn the pair's settlement slot
      // on a no-op and deny a later, corrected count.
      if (!line.isMoneyTrack && line.returnedCrates <= 0) continue;

      // Idempotency guard 2 of 2, #188 (PRD #155 US 14) — the PARTITIONED
      // double-Confirm. Claim this (order, manufacturer) pair's settlement slot
      // and skip the WHOLE pair when a prior Confirm already holds it: physical
      // empties, crate-track netting, AND the money-track deposit. Unlike the
      // status re-read in [confirm], this survives convergence — the claim rides
      // the `order_crate_lines` row both devices already share.
      final hasClaim = await _db.orderCrateLinesDao.claimSettlement(
        orderId: orderId,
        manufacturerId: line.manufacturerId,
        settledBy: staffId,
      );
      if (!hasClaim) continue;

      // 1. Physical crate stock comes back regardless of how it's settled.
      if (line.returnedCrates > 0) {
        await _db.inventoryDao.addEmptyCrates(
          line.manufacturerId,
          line.returnedCrates,
          storeId: storeId,
          orderId: orderId,
        );
      }

      if (line.isMoneyTrack) {
        // §13.4 money-track: the obligation lived in the credit balance as a
        // held deposit — settle it in money (refund / forfeit / shortfall).
        // No crate balance was issued for this brand, so DON'T touch the
        // crate ledger (that would create a phantom credit).
        await _ordersDao.settleCrateDepositReturn(
          customerId: customerId,
          manufacturerId: line.manufacturerId,
          orderId: orderId,
          takenCrates: line.takenCrates,
          returnedCrates: line.returnedCrates,
          rateKobo: line.rateKobo,
          paidKobo: line.paidKobo,
          refundAsCash: refundAsCash,
          performedBy: staffId,
        );
      } else if (line.returnedCrates > 0) {
        // crate-track (no deposit): net the issued balance. Leftover (taken −
        // returned) stays as crate debt on the crates tab. The ledger id is
        // DETERMINISTIC per (order, manufacturer) for the same reason the money
        // legs are (#188) — a partitioned second Confirm must not net twice.
        await _db.cratePoolDao.recordCrateReturnByCustomer(
          customerId: customerId,
          manufacturerId: line.manufacturerId,
          quantity: line.returnedCrates,
          performedBy: staffId,
          orderId: orderId,
          ledgerId: OrdersDao.settlementLegId(
            orderId: orderId,
            manufacturerId: line.manufacturerId,
            referenceType: 'crate_track_return',
          ),
        );
      }
    }
  }

  /// **Cancel** / refund an order (§19.7): reverses stock, payments, and the
  /// credit-balance legs so the customer's credit balance returns to its
  /// pre-sale balance.
  Future<void> cancel(String orderId, String reason, String staffId) {
    return _ordersDao.markCancelled(orderId, reason, staffId);
  }

  Future<void> assignRider(String orderId, String riderName) {
    return _ordersDao.assignRider(orderId, riderName);
  }

  /// The best-effort, non-transactional reactions to a checked-out sale — quick
  /// sale audit and customer crate-debt notification (Q8/C, ADR 0004). Isolated
  /// from the settlement core: a reader knows the money/inventory/crate work is
  /// already done and these can never fail checkout (each is guarded).
  Future<void> _runPostCheckoutSideEffects({
    required String orderId,
    required String orderNumber,
    required List<Map<String, dynamic>> cart,
    required String? customerId,
    required String staffId,
    required String storeId,
  }) async {
    // §12.3 / §26.4: a Quick Sale is an off-inventory line. Once the sale is
    // accepted (a server-rejected sale rethrows before this and never reaches
    // here), record it in the activity log and alert CEO + Manager for audit.
    final quickLines = cart
        .where((c) {
          final id = c['id'] as String?;
          return id == null || id.isEmpty;
        })
        .toList(growable: false);
    if (quickLines.isNotEmpty) {
      await _auditQuickSale(
        orderId: orderId,
        orderNumber: orderNumber,
        staffId: staffId,
        storeId: storeId,
        quickLines: quickLines,
      );
    }

    // §12.1 / §26.4: a sale that leaves a registered customer OWING crates
    // (the no-deposit "crate-track" path) alerts CEO + Manager. Best-effort —
    // the sale is already recorded; a failure here must never fail checkout.
    await _notifyCrateDebt(
      orderId: orderId,
      orderNumber: orderNumber,
      customerId: customerId,
      staffId: staffId,
    );
  }

  /// §12.1 / §26.4: notify CEO + Manager when a sale leaves the customer owing
  /// empty crates. Owing arises only on the no-deposit ("crate-track") path —
  /// `order_crate_lines` with `depositPaidKobo == 0` — where `createOrder`
  /// issued crates against the customer's balance. We read the post-sale
  /// per-manufacturer balance and fire only for brands the customer now owes
  /// (balance > 0); a settled or credit balance (≤ 0) fires nothing (§12.2).
  Future<void> _notifyCrateDebt({
    required String orderId,
    required String orderNumber,
    required String? customerId,
    required String staffId,
  }) async {
    if (customerId == null || customerId.isEmpty) return;
    try {
      final lines = await _db.orderCrateLinesDao.getForOrder(orderId);
      final owedMfrIds = lines
          .where((l) => l.depositPaidKobo == 0 && l.cratesTaken > 0)
          .map((l) => l.manufacturerId)
          .toSet();
      if (owedMfrIds.isEmpty) return;

      final balances = await _db.customersDao
          .watchCrateBalancesWithGroups(customerId)
          .first;
      final owing = balances
          .where((b) => owedMfrIds.contains(b.manufacturerId) && b.balance > 0)
          .toList();
      if (owing.isEmpty) return;

      final customer = await _db.customersDao.findById(customerId);
      final who = (customer?.name.trim().isNotEmpty ?? false)
          ? customer!.name.trim()
          : 'Customer';
      final summary = owing
          .map((b) => '${b.balance} ${b.manufacturerName}')
          .join(', ');
      final message = '$who now owes crates after $orderNumber: $summary';

      final recipients = await _db.userBusinessesDao.getUserIdsForRoleSlugs([
        'ceo',
        'manager',
      ]);
      for (final uid in (recipients.isEmpty ? [staffId] : recipients)) {
        await _db.notificationsDao.fireNotification(
          type: 'customer_crate_debt',
          message: message,
          severity: 'warning',
          linkedRecordId: orderId,
          recipientUserId: uid,
        );
      }
    } catch (e) {
      debugPrint('[OrderCommands] crate-debt notify failed (non-fatal): $e');
    }
  }

  /// §12.3 / §26.4: audit a Quick Sale — write an activity-log entry and fire a
  /// CEO + Manager notification (Quick Sales bypass inventory, so they are
  /// tracked for oversight). Best-effort: a failure here must not fail the sale,
  /// which is already recorded.
  Future<void> _auditQuickSale({
    required String orderId,
    required String orderNumber,
    required String staffId,
    required String storeId,
    required List<Map<String, dynamic>> quickLines,
  }) async {
    try {
      final summary = quickLines
          .map((c) {
            final name = (c['name'] as String?)?.trim();
            final qty = (c['qty'] as num?)?.toString() ?? '1';
            return '$qty× ${name == null || name.isEmpty ? 'Quick Sale' : name}';
          })
          .join(', ');

      await _db.activityLogDao.log(
        action: 'quick_sale',
        description: 'Quick Sale on $orderNumber: $summary',
        staffId: staffId,
        storeId: storeId,
        orderId: orderId,
      );

      final recipients = await _db.userBusinessesDao.getUserIdsForRoleSlugs([
        'ceo',
        'manager',
      ]);
      for (final uid in (recipients.isEmpty ? [staffId] : recipients)) {
        await _db.notificationsDao.fireNotification(
          type: 'quick_sale_used',
          message: 'Quick Sale on $orderNumber: $summary',
          severity: 'warning',
          linkedRecordId: orderId,
          recipientUserId: uid,
        );
      }
    } catch (e) {
      debugPrint('[OrderCommands] quick-sale audit failed (non-fatal): $e');
    }
  }

  /// Reverses the local writes performed by `OrdersDao.createOrder` when
  /// the server's `pos_record_sale` RPC permanently rejected the sale
  /// (e.g. insufficient_stock from a concurrent device). The cloud never
  /// saw any of this — the RPC rolled back its own transaction — so the
  /// compensation is purely local. Delegates to
  /// [OrdersDao.reverseRejectedSaleLocal] so the foreground (online checkout)
  /// path and the background cashier-Cancel path share ONE complete reversal:
  /// order cancelled + inventory refunded + the wallet double-entry reversed
  /// (a v2 registered sale posts wallet legs locally, so this MUST undo them or
  /// a rejected credit sale would leave the customer wrongly debited).
  Future<void> _compensateRejectedSale(
    String orderId,
    List<OrderItemsCompanion> items,
    String staffId,
  ) async {
    final lines = <({String productId, String storeId, int quantity})>[
      for (final item in items)
        // Quick-sale line (§26.4): no product → nothing was deducted.
        if (item.productId.value != null)
          (
            productId: item.productId.value!,
            storeId: item.storeId.value,
            quantity: item.quantity.value,
          ),
    ];
    await _ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: lines,
      staffId: staffId,
    );
  }

  /// Cashier-initiated Cancel of a sale the server permanently REJECTED
  /// (invoked from the `sale_rejected` notification's Cancel action). The v2
  /// sale wrote no local `order_items`, so the sold lines are rebuilt from the
  /// orphaned envelope's `p_items`, then the complete local reversal runs
  /// (cancel order + refund inventory + reverse wallet). Idempotent — safe to
  /// tap twice, and safe if the orphan has already been cleaned up.
  Future<void> cancelRejectedSale(String orderId, String staffId) async {
    final payloadJson = await _db.syncDao.rejectedSalePayload(orderId);
    final lines = <({String productId, String storeId, int quantity})>[];
    if (payloadJson != null) {
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      final storeId = payload['p_store_id'];
      final rawItems = payload['p_items'];
      if (rawItems is List && storeId is String) {
        for (final it in rawItems) {
          if (it is! Map) continue;
          final pid = it['product_id'];
          final qty = it['quantity'];
          if (pid is String && qty is int) {
            lines.add((productId: pid, storeId: storeId, quantity: qty));
          }
        }
      }
    }
    // Even with no recoverable lines (orphan already gone), still cancel the
    // phantom order header so the local view is consistent.
    await _ordersDao.reverseRejectedSaleLocal(
      orderId: orderId,
      items: lines,
      staffId: staffId,
    );
  }

  /// Cashier-initiated Cancel of a rejected sale from the **Sync Issues** screen
  /// (#150) — the fallback route when the `sale_rejected` notification was
  /// swipe-dismissed. Runs the complete local reversal FIRST via
  /// [cancelRejectedSale] — which sources the sold lines from the orphaned
  /// envelope's `p_items` — and only THEN clears the orphan ([orphanId]).
  ///
  /// The order is load-bearing: discarding the orphan first would delete the
  /// `p_items` payload the reversal depends on, so inventory would never be
  /// refunded (never discard-then-recover). Idempotent, and safe if the orphan
  /// has already been cleaned up.
  Future<void> cancelRejectedSaleFromOrphan({
    required String orderId,
    required String orphanId,
    required String staffId,
  }) async {
    await cancelRejectedSale(orderId, staffId);
    await _db.syncDao.discardOrphan(orphanId);
  }

  String _resolvePaymentType({
    required String paymentSubType,
    required int amountPaidKobo,
    required int totalAmountKobo,
    required int walletBalanceKobo,
  }) {
    if (paymentSubType == 'wallet') return 'wallet';
    if (amountPaidKobo <= 0) {
      // A "credit sale" the customer's EXISTING wallet credit fully covers is
      // financially a wallet payment — _resolveWalletDebit debits the full total
      // for both 'credit' and 'wallet', so this is a label change only, no ledger
      // change. Record it as wallet so receipt/badge reflect what settled it.
      return walletBalanceKobo >= totalAmountKobo ? 'wallet' : 'credit';
    }
    if (amountPaidKobo < totalAmountKobo) return 'mixed';
    return 'cash';
  }

  int _resolveWalletDebit({
    required String dbPaymentType,
    required int amountPaidKobo,
    required int totalAmountKobo,
  }) {
    switch (dbPaymentType) {
      case 'wallet':
      case 'credit':
        return totalAmountKobo;
      case 'mixed':
        return totalAmountKobo - amountPaidKobo;
      default:
        return 0;
    }
  }

  String _resolvePaymentMethod(String paymentSubType) {
    if (paymentSubType == 'wallet') return 'wallet';
    if (paymentSubType == 'transfer') return 'transfer';
    if (paymentSubType == 'card' || paymentSubType == 'pos') {
      return paymentSubType;
    }
    return 'cash';
  }

  List<OrderItemsCompanion> _buildOrderItems({
    required List<Map<String, dynamic>> cart,
    required String orderId,
    required String storeId,
  }) {
    final businessId = _ordersDao.requireBusinessId();
    return cart
        .map((item) {
          // §12.3 Quick Sale: an item not in inventory has no product id. It is
          // recorded as a real order line with productId == null; its name is
          // carried in the priceSnapshot below. Quick-sale lines bypass
          // inventory (§26.4) — OrdersDao.createOrder skips the stock writes.
          final rawId = item['id'] as String?;
          final productId = (rawId == null || rawId.isEmpty) ? null : rawId;

          final qty = (item['qty'] as num).toInt();
          // Prefer the integer kobo snapshot; fall back to the legacy double
          // 'price' (Naira) for carts seeded before line-version tracking.
          final unitPriceKobo =
              (item['unitPriceKobo'] as int?) ??
              ((item['price'] as num).toDouble() * 100).round();
          final buyingPriceKobo = (item['buyingPriceKobo'] as int?) ?? 0;
          final totalKobo = unitPriceKobo * qty;
          final version = item['version'] as int?;
          // #176 — capture the catalogue (tier list) price so a custom-price
          // concession is derivable in margin review. The cart keeps
          // `catalogPriceKobo` as the immutable designated price while
          // `unitPriceKobo` becomes the CHARGED (possibly custom) price. Store it
          // only when the two differ (an actual concession); NULL otherwise so a
          // full-price line records no phantom concession.
          final catalogPriceKobo = item['catalogPriceKobo'] as int?;
          final cataloguePriceKobo =
              (catalogPriceKobo != null && catalogPriceKobo != unitPriceKobo)
              ? catalogPriceKobo
              : null;

          final snapshot = jsonEncode({
            'name': item['name'],
            'unitPriceKobo': unitPriceKobo,
            if (version != null) 'version': version,
          });

          return OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: qty,
            unitPriceKobo: unitPriceKobo,
            buyingPriceKobo: Value(buyingPriceKobo),
            totalKobo: totalKobo,
            cataloguePriceKobo: Value(cataloguePriceKobo),
            priceSnapshot: Value(snapshot),
          );
        })
        .toList(growable: false);
  }
}
