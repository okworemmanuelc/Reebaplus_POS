part of 'daos.dart';

// ── Sale adjustments: part return (#712, ADR 0035) ──────────────────────────
//
// A part return never edits the sale. It writes a NEW `orders` row
// (`kind = 'adjustment'`, `adjusts_order_id` = the sale) with MINUS lines, and
// every stock / cost / payment / wallet / crate row it writes references THAT
// row's id. The sale stays exactly as it was, so every ledger stays append-only
// and every report counts the adjustment on its own `created_at` day.
//
// Rules (the numbers are all derived from rows, so two phones agree):
//   * Returnable per line = the sale line's quantity minus the minus lines of
//     every adjustment that points at it (the link is `price_snapshot`
//     `adjusts_line_id` on the minus line).
//   * Prices on returned lines stay at the ORIGINAL line price and cost.
//   * Discount: the sale's order-level discount is shared out pro rata over the
//     gross still standing; the return that takes everything left takes the
//     rest, so the shares add up to the discount exactly.
//   * Money is proportional to what was actually paid: goods value G is
//     reversed on the customer's account in full (`refund` credit); the part of
//     G that was paid (G x paid-standing / goods-standing) leaves as a `refund`
//     cash-out row (and a `void` of the payment credit leg), or stays as credit
//     when the destination is the balance. The unpaid rest simply cancels debt.
//     The adjustment header records `-paidShare` in `amount_paid_kobo`, which is
//     what makes "paid still standing" derivable for the next return.
//   * Crates of crate-tracked bottle lines: see
//     [CratePoolDao.returnCratesForAdjustment]; deposit still held is released
//     pro rata by crates.

/// What a part return would do, computed once and used both by the pop-up
/// (preview) and by the write.
class PartReturnPlan {
  const PartReturnPlan({
    required this.parent,
    required this.lines,
    required this.qtyByLine,
    required this.grossKobo,
    required this.discountShareKobo,
    required this.paidShareKobo,
    required this.depositRefundKobo,
    required this.cratesByBrand,
    required this.emptiesToHandBack,
    required this.coversEverythingLeft,
  });

  final OrderData parent;
  final List<OrderItemData> lines;

  /// Parent-line id -> units returned (only above 0).
  final Map<String, double> qtyByLine;
  final int grossKobo;
  final int discountShareKobo;

  /// Of the goods value, what was actually paid (refundable).
  final int paidShareKobo;
  final int depositRefundKobo;

  /// Brand id -> crates coming back (crate-tracked bottle lines only).
  final Map<String, double> cratesByBrand;
  final List<ReturnEmpties> emptiesToHandBack;

  /// True when this return takes every unit still returnable.
  final bool coversEverythingLeft;

  int get goodsKobo => grossKobo - discountShareKobo;

  /// Money the cashier may hand back or credit: paid goods + deposit.
  int get refundableKobo => paidShareKobo + depositRefundKobo;
}

/// The result of a part return, for the audit trail and the success message.
class PartReturnOutcome {
  const PartReturnOutcome({
    required this.adjustmentOrderId,
    required this.adjustmentOrderNumber,
    required this.parentOrderNumber,
    required this.storeId,
    required this.goodsKobo,
    required this.refundKobo,
    required this.damagedUnits,
  });
  final String adjustmentOrderId;
  final String adjustmentOrderNumber;
  final String parentOrderNumber;
  final String? storeId;
  final int goodsKobo;
  final int refundKobo;
  final double damagedUnits;
}

/// `price_snapshot` key on a minus line: the sale line it returns units of.
const String kAdjustsLineKey = 'adjusts_line_id';

/// The sale line a minus [line] returns units of, or null.
String? adjustsLineIdOf(OrderItemData line) {
  final snap = line.priceSnapshot;
  if (snap == null) return null;
  try {
    final decoded = jsonDecode(snap);
    if (decoded is Map && decoded[kAdjustsLineKey] is String) {
      return decoded[kAdjustsLineKey] as String;
    }
  } catch (_) {}
  return null;
}

extension SaleAdjustments on OrdersDao {
  /// The adjustments of [orderId], newest first. Business scoped.
  Future<List<OrderData>> adjustmentsOf(String orderId) =>
      (select(orders)
            ..where(
              (o) =>
                  whereBusiness(o) &
                  o.kind.equals('adjustment') &
                  o.adjustsOrderId.equals(orderId),
            )
            ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
          .get();

  /// Live feed of [adjustmentsOf], for the order details.
  Stream<List<OrderData>> watchAdjustmentsOf(String orderId) =>
      (select(orders)
            ..where(
              (o) =>
                  whereBusiness(o) &
                  o.kind.equals('adjustment') &
                  o.adjustsOrderId.equals(orderId),
            )
            ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
          .watch();

  /// Live part returns of [orderId] with their minus lines (and products).
  Stream<List<({OrderData adjustment, List<OrderItemDataWithProductData> lines})>>
  watchAdjustmentsWithLines(String orderId) {
    return watchAdjustmentsOf(orderId).asyncMap((adjs) async {
      final out = <({OrderData adjustment, List<OrderItemDataWithProductData> lines})>[];
      for (final a in adjs) {
        final rows = await (select(orderItems).join([
          leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
        ])..where(orderItems.orderId.equals(a.id) & whereBusiness(orderItems)))
            .get();
        out.add((
          adjustment: a,
          lines: [
            for (final r in rows)
              OrderItemDataWithProductData(
                r.readTable(orderItems),
                r.readTableOrNull(products),
              ),
          ],
        ));
      }
      return out;
    });
  }

  /// Units still returnable per line of [orderId] (line id -> units, never
  /// below 0): the original quantity minus every adjustment's minus lines.
  Future<Map<String, double>> returnableQtyByLine(String orderId) async {
    final lines = await (select(orderItems)
          ..where((i) => i.orderId.equals(orderId) & whereBusiness(i)))
        .get();
    final adjIds = [for (final a in await adjustmentsOf(orderId)) a.id];
    final returned = <String, double>{};
    if (adjIds.isNotEmpty) {
      final minus = await (select(orderItems)
            ..where((i) => i.orderId.isIn(adjIds) & whereBusiness(i)))
          .get();
      for (final m in minus) {
        final target = adjustsLineIdOf(m);
        if (target == null) continue;
        returned[target] = (returned[target] ?? 0) - m.quantity;
      }
    }
    return {
      for (final l in lines)
        l.id: math.max(0.0, l.quantity - (returned[l.id] ?? 0)),
    };
  }

  /// Crates per brand that [qtyByLine]-shaped (line, units) pairs carry: units
  /// of crate-tracked bottle lines grouped by manufacturer, the same basis as
  /// `cratesTakenByManufacturer`. Empty when the business does not track crates.
  Future<Map<String, double>> _crateUnitsByBrand(
    Iterable<({OrderItemData line, double qty})> pairs,
  ) async {
    final biz = await (select(businesses)
          ..where((b) => b.id.equals(requireBusinessId()))
          ..limit(1))
        .getSingleOrNull();
    final tracksCrates = crateTrackingOn(
      businessType: biz?.type,
      tracksEmptyCrates: biz?.tracksEmptyCrates,
    );
    final out = <String, double>{};
    if (!tracksCrates) return out;
    for (final p in pairs) {
      final productId = p.line.productId;
      if (productId == null || p.qty <= 0) continue;
      final product = await (select(products)
            ..where((x) => x.id.equals(productId) & whereBusiness(x))
            ..limit(1))
          .getSingleOrNull();
      final mfr = product?.manufacturerId;
      if (product == null || mfr == null) continue;
      if (product.unit?.toLowerCase() != 'bottle' || !product.trackEmpties) {
        continue;
      }
      out[mfr] = (out[mfr] ?? 0) + p.qty;
    }
    return out;
  }

  /// Works out a part return of [orderId] without writing anything. Throws a
  /// [ReturnRefusedException] when it cannot be done (not a completed sale, a
  /// bad or over-the-limit quantity, nothing picked, deposit kept).
  Future<PartReturnPlan> planPartReturn(
    String orderId,
    Map<String, double> qtyByLineId,
  ) async {
    final parent = await findById(orderId);
    if (parent == null || parent.kind != 'sale') {
      throw const ReturnRefusedException(ReturnRefusal.notFound);
    }
    final refusal = await returnRefusal(orderId);
    if (refusal != null) throw ReturnRefusedException(refusal);

    final lines = await (select(orderItems)
          ..where((i) => i.orderId.equals(orderId) & whereBusiness(i)))
        .get();
    final byId = {for (final l in lines) l.id: l};
    final returnable = await returnableQtyByLine(orderId);

    final qty = <String, double>{};
    for (final e in qtyByLineId.entries) {
      if (e.value == 0) continue;
      final line = byId[e.key];
      if (line == null || e.value < 0 || !Qty.isQuarterStep(e.value)) {
        throw const ReturnRefusedException(ReturnRefusal.badReturnQty);
      }
      if (e.value > (returnable[e.key] ?? 0) + 1e-9) {
        throw const ReturnRefusedException(ReturnRefusal.overReturn);
      }
      qty[e.key] = e.value;
    }
    if (qty.isEmpty) {
      throw const ReturnRefusedException(ReturnRefusal.nothingToReturn);
    }

    final adjs = await adjustmentsOf(orderId);
    var remainingGross = 0;
    var returnedGross = 0;
    var coversAll = true;
    for (final l in lines) {
      final left = returnable[l.id] ?? 0;
      remainingGross += lineTotalKobo(l.unitPriceKobo, left);
      final q = qty[l.id] ?? 0;
      returnedGross += lineTotalKobo(l.unitPriceKobo, q);
      if (left > 0 && (q - left).abs() > 1e-9) coversAll = false;
    }

    // Discount: pro rata over what is left; the last return takes the rest.
    final usedDiscount = adjs.fold<int>(0, (s, a) => s + (-a.discountKobo));
    final remainingDiscount = math.max(0, parent.discountKobo - usedDiscount);
    final share = coversAll
        ? remainingDiscount
        : (remainingGross > 0
              ? (remainingDiscount * returnedGross / remainingGross).round()
              : 0);
    final int discountShare = share.clamp(0, remainingDiscount).toInt();
    final goods = returnedGross - discountShare;
    final remainingGoods = remainingGross - remainingDiscount;

    // Paid still standing on the goods: tendered `sale` rows minus what earlier
    // adjustments already released (their header carries -paidShare).
    final salePays = await (select(paymentTransactions)..where(
          (p) =>
              p.orderId.equals(orderId) &
              whereBusiness(p) &
              p.voidedAt.isNull() &
              p.type.equals('sale'),
        ))
        .get();
    final tendered = salePays.fold<int>(
      0,
      (s, p) => s + (p.amountKobo > 0 ? p.amountKobo : 0),
    );
    final released = adjs.fold<int>(0, (s, a) => s + (-a.amountPaidKobo));
    final paidStanding = math.max(0, tendered - released);
    final paidShare = coversAll
        ? paidStanding
        : (remainingGoods > 0
              ? (goods * paidStanding / remainingGoods).round()
              : 0);
    final int paid = paidShare
        .clamp(0, math.min(paidStanding, math.max(0, goods)))
        .toInt();

    // Crates and the deposit still held.
    final crateReturned = await _crateUnitsByBrand([
      for (final e in qty.entries) (line: byId[e.key]!, qty: e.value),
    ]);
    final crateLeft = await _crateUnitsByBrand([
      for (final l in lines) (line: l, qty: returnable[l.id] ?? 0),
    ]);
    final orderIds = [orderId, for (final a in adjs) a.id];
    final depositRows = await (select(walletTransactions)..where(
          (t) =>
              whereBusiness(t) &
              t.orderId.isIn(orderIds) &
              t.referenceType.isIn(const [
                'crate_deposit',
                'crate_deposit_refunded',
                'crate_deposit_forfeited',
              ]),
        ))
        .get();
    var held = 0;
    for (final r in depositRows) {
      held += r.referenceType == 'crate_deposit' ? r.amountKobo : -r.amountKobo;
    }
    held = math.max(0, held);
    final returnedCrates = crateReturned.values.fold<double>(0, (s, v) => s + v);
    final leftCrates = crateLeft.values.fold<double>(0, (s, v) => s + v);
    final deposit = held == 0 || returnedCrates == 0
        ? 0
        : (coversAll || returnedCrates >= leftCrates
              ? held
              : (held * returnedCrates / leftCrates).round());

    // Empties to hand back (preview of what returnCratesForAdjustment will do).
    final back = await db.cratePoolDao.emptiesBackFor(
      orderIds: orderIds,
      returnedByBrand: crateReturned,
    );
    final names = <ReturnEmpties>[];
    if (back.isNotEmpty) {
      final brands = await (select(db.manufacturers)
            ..where((m) => m.id.isIn(back.keys.toList()) & whereBusiness(m)))
          .get();
      final nameOf = {for (final m in brands) m.id: m.name};
      for (final e in back.entries) {
        names.add(ReturnEmpties(nameOf[e.key] ?? 'Crates', e.value));
      }
    }

    return PartReturnPlan(
      parent: parent,
      lines: lines,
      qtyByLine: qty,
      grossKobo: returnedGross,
      discountShareKobo: discountShare,
      paidShareKobo: paid,
      depositRefundKobo: deposit,
      cratesByBrand: crateReturned,
      emptiesToHandBack: names,
      coversEverythingLeft: coversAll,
    );
  }

  /// **Part return** (#712): ONE transaction, behind the #550 guarded reversal,
  /// that writes a sale adjustment for [qtyByLineId] (parent-line id -> units).
  /// Rows written (all referencing the adjustment's id): the adjustment `orders`
  /// row + minus `order_items`; per stocked line a `return` stock row, inventory
  /// back up and a cost layer at the line's recorded cost (damaged units are
  /// written off as `damage:<key>`, #551); the money rows (see the file header);
  /// the crate rows of [CratePoolDao.returnCratesForAdjustment]. The cloud's
  /// `pos_claim_sale_adjustment` envelope holds them all until it accepts, so
  /// two phones cannot return more than was sold.
  ///
  /// A full return of a sale with NO adjustment yet is [markCancelled]'s job
  /// (the caller decides); this works for any quantities that fit, including
  /// the final adjustment that takes everything left.
  Future<PartReturnOutcome> returnPartOfSale({
    required String orderId,
    required Map<String, double> qtyByLineId,
    required String reason,
    required String staffId,
    required String deviceTag,
    RefundDestination destination = RefundDestination.cashOrTransfer,
    String? refundMethod,
    Map<String, double> damagedQtyByLine = const {},
    String damageReasonKey = 'other',
  }) {
    assert(
      refundMethod == null || refundMethod == 'cash' || refundMethod == 'transfer',
    );
    final toBalance = destination == RefundDestination.balance;
    return db.transaction(() async {
      final plan = await planPartReturn(orderId, qtyByLineId);
      final parent = plan.parent;
      if (toBalance && parent.customerId == null) {
        throw const ReturnRefusedException(ReturnRefusal.noCustomerBalance);
      }
      final byId = {for (final l in plan.lines) l.id: l};
      var damagedUnits = 0.0;
      for (final e in damagedQtyByLine.entries) {
        final line = byId[e.key];
        final q = plan.qtyByLine[e.key] ?? 0;
        if (e.value < 0 ||
            !Qty.isQuarterStep(e.value) ||
            line == null ||
            e.value > q ||
            (e.value > 0 && line.productId == null)) {
          throw const ReturnRefusedException(ReturnRefusal.badDamagedQty);
        }
        damagedUnits += e.value;
      }
      if (damagedUnits > 0 && !kReturnDamageKeys.contains(damageReasonKey)) {
        throw const ReturnRefusedException(ReturnRefusal.badDamageReason);
      }

      final now = DateTime.now();
      final adjustmentId = UuidV7.generate();
      final adjustmentNumber = await generateOrderNumber(deviceTag);
      final guard = await beginGuardedReversal();

      // The adjustment header: born completed, today, NEGATIVE goods totals.
      // `cancellation_reason` carries the return reason (the column's only
      // free-text slot); it never means "cancelled" on a kind = 'adjustment'.
      final goods = plan.goodsKobo;
      final header = OrdersCompanion.insert(
        id: Value(adjustmentId),
        businessId: requireBusinessId(),
        orderNumber: adjustmentNumber,
        customerId: Value(parent.customerId),
        totalAmountKobo: -goods,
        discountKobo: Value(-plan.discountShareKobo),
        netAmountKobo: -goods,
        amountPaidKobo: Value(-plan.paidShareKobo),
        paymentType: parent.paymentType,
        status: 'completed',
        cancellationReason: Value(reason),
        staffId: Value(staffId),
        storeId: Value(parent.storeId),
        vanTripId: Value(parent.vanTripId),
        kind: const Value('adjustment'),
        adjustsOrderId: Value(orderId),
        completedAt: Value(now),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(orders).insert(header);
      await db.syncDao.enqueueUpsert('orders', header);

      final claimLines = <Map<String, dynamic>>[];
      for (final entry in plan.qtyByLine.entries) {
        final line = byId[entry.key]!;
        final q = entry.value;
        final damaged = damagedQtyByLine[line.id] ?? 0;
        final minusId = UuidV7.generate();

        // The minus line: original price and cost; the link back to the sale
        // line rides in `price_snapshot` (a quick-sale name is kept).
        var snapshot = <String, dynamic>{};
        if (line.priceSnapshot != null) {
          try {
            final decoded = jsonDecode(line.priceSnapshot!);
            if (decoded is Map) snapshot = Map<String, dynamic>.from(decoded);
          } catch (_) {}
        }
        snapshot[kAdjustsLineKey] = line.id;
        final minus = OrderItemsCompanion.insert(
          id: Value(minusId),
          businessId: requireBusinessId(),
          orderId: adjustmentId,
          productId: Value(line.productId),
          storeId: line.storeId,
          quantity: -q,
          unitPriceKobo: line.unitPriceKobo,
          buyingPriceKobo: Value(line.buyingPriceKobo),
          totalKobo: -lineTotalKobo(line.unitPriceKobo, q),
          cataloguePriceKobo: Value(line.cataloguePriceKobo),
          priceSnapshot: Value(jsonEncode(snapshot)),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(orderItems).insert(minus);
        await db.syncDao.enqueueUpsert('order_items', minus);
        claimLines.add({'order_item_id': line.id, 'quantity': q});

        final productId = line.productId;
        if (productId == null) continue; // quick sale: never stocked

        final stock = StockTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          productId: productId,
          locationId: line.storeId,
          quantityDelta: q,
          movementType: 'return',
          orderId: Value(adjustmentId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(now),
        );
        await into(stockTransactions).insert(stock);
        await db.syncDao.enqueueUpsert('stock_transactions', stock);
        await customUpdate(
          'UPDATE inventory SET quantity = quantity + ? '
          'WHERE business_id = ? AND product_id = ? AND store_id = ?',
          variables: [
            Variable(q),
            Variable(requireBusinessId()),
            Variable(productId),
            Variable(line.storeId),
          ],
          updates: {inventory},
        );
        final invRow = await (select(inventory)..where(
              (t) =>
                  t.productId.equals(productId) &
                  t.storeId.equals(line.storeId) &
                  whereBusiness(t),
            ))
            .getSingle();
        await db.syncDao.enqueueUpsert('inventory', invRow);

        // The units come back as a cost layer at the line's recorded cost; the
        // id is fixed from the MINUS line so the cloud recost can recognise it.
        await db.costBatchesDao.recordInflowBatch(
          productId: productId,
          storeId: line.storeId,
          quantity: q - damaged,
          costKobo: line.buyingPriceKobo,
          id: CostBatchesDao.cancelRestoreLayerId(minusId),
          allowEmpty: true,
        );
      }

      await _postPartReturnMoney(
        plan: plan,
        adjustmentId: adjustmentId,
        staffId: staffId,
        reason: reason,
        destination: destination,
        refundMethod: refundMethod,
        now: now,
      );

      // Crates: cancel what is still owed, hand back the rest.
      final adjs = await adjustmentsOf(orderId);
      await db.cratePoolDao.returnCratesForAdjustment(
        orderIds: [orderId, for (final a in adjs) a.id],
        adjustmentOrderId: adjustmentId,
        returnedByBrand: plan.cratesByBrand,
        staffId: staffId,
      );

      // #551 — damaged units written off at the line's recorded cost.
      for (final e in damagedQtyByLine.entries) {
        final line = byId[e.key];
        final productId = line?.productId;
        if (line == null || productId == null || e.value <= 0) continue;
        await db.inventoryDao.adjustStock(
          productId,
          line.storeId,
          -e.value,
          'damage:$damageReasonKey',
          staffId,
          outflowValueKobo: lineTotalKobo(line.buyingPriceKobo, e.value),
        );
      }

      // Claim: the cloud accepts this adjustment only if it fits what was sold;
      // every row above is held until it does.
      final businessId = requireBusinessId();
      final held = (await db.syncDao.queueRowIds(
        businessId,
      )).difference(guard.queueBefore).toList();
      await db.syncDao.enqueue(
        kAdjustmentClaimAction,
        jsonEncode(<String, dynamic>{
          'p_business_id': businessId,
          'p_actor_id': staffId,
          'p_parent_order_id': orderId,
          'p_adjustment_order_id': adjustmentId,
          'p_reversal_id': guard.reversalId,
          'p_lines': claimLines,
        }),
      );
      await db.syncDao.holdRowsByOrder(held, guard.reversalId);

      return PartReturnOutcome(
        adjustmentOrderId: adjustmentId,
        adjustmentOrderNumber: adjustmentNumber,
        parentOrderNumber: parent.orderNumber,
        storeId: parent.storeId,
        goodsKobo: goods,
        refundKobo: toBalance ? 0 : plan.refundableKobo,
        damagedUnits: damagedUnits,
      );
    });
  }

  /// The money rows of a part return (see the file header). All reference
  /// [adjustmentId].
  Future<void> _postPartReturnMoney({
    required PartReturnPlan plan,
    required String adjustmentId,
    required String staffId,
    required String reason,
    required RefundDestination destination,
    required String? refundMethod,
    required DateTime now,
  }) async {
    final toBalance = destination == RefundDestination.balance;
    final parent = plan.parent;
    final goods = plan.goodsKobo;
    final customerId = parent.customerId;

    // The payment rows come first: they are the cash that leaves the till.
    final salePay = await (select(paymentTransactions)
          ..where(
            (p) =>
                p.orderId.equals(parent.id) &
                whereBusiness(p) &
                p.voidedAt.isNull() &
                p.type.equals('sale') &
                p.amountKobo.isBiggerThanValue(0),
          )
          ..limit(1))
        .getSingleOrNull();
    if (plan.paidShareKobo > 0 && !toBalance && salePay != null) {
      await db.paymentTransactionsDao.postReversalPayment(
        original: salePay.copyWith(orderId: Value(adjustmentId)),
        reversalType: 'refund',
        method: refundMethod,
        performedBy: staffId,
        amountKobo: plan.paidShareKobo,
        reason: 'order_part_returned: $reason',
        at: now,
      );
    }

    if (customerId != null) {
      final wallet = await (select(customerWallets)
            ..where(
              (w) =>
                  whereBusiness(w) &
                  w.customerId.equals(customerId) &
                  w.isDeleted.not(),
            )
            ..limit(1))
          .getSingleOrNull();
      if (wallet == null) {
        throw StateError('Customer $customerId has no wallet — cannot return');
      }
      Future<void> leg(String type, int amount, String referenceType) async {
        if (amount <= 0) return;
        final comp = WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          walletId: wallet.id,
          customerId: customerId,
          type: type,
          amountKobo: amount,
          signedAmountKobo: type == 'credit' ? amount : -amount,
          referenceType: referenceType,
          orderId: Value(adjustmentId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(now),
        );
        await into(walletTransactions).insert(comp);
        await db.syncDao.enqueueUpsert('wallet_transactions', comp);
      }

      // The goods debit comes back off the account in full...
      await leg('credit', goods, 'refund');
      // ...and the paid part leaves with the cash (or stays as credit).
      if (!toBalance && salePay != null) {
        await leg('debit', plan.paidShareKobo, 'void');
      }

      // The deposit still held, pro rata by crates.
      if (plan.depositRefundKobo > 0) {
        await leg('debit', plan.depositRefundKobo, 'crate_deposit_refunded');
        if (toBalance) {
          await leg('credit', plan.depositRefundKobo, 'crate_refund');
        }
      }
    }
    if (plan.depositRefundKobo > 0 && !toBalance) {
      final depositPay = await (select(paymentTransactions)
            ..where(
              (p) =>
                  p.orderId.equals(parent.id) &
                  whereBusiness(p) &
                  p.voidedAt.isNull() &
                  p.type.equals('crate_deposit') &
                  p.amountKobo.isBiggerThanValue(0),
            )
            ..limit(1))
          .getSingleOrNull();
      if (depositPay != null) {
        await db.paymentTransactionsDao.postReversalPayment(
          original: depositPay.copyWith(orderId: Value(adjustmentId)),
          reversalType: 'crate_deposit',
          performedBy: staffId,
          amountKobo: -plan.depositRefundKobo,
          reason: 'order_part_returned: $reason',
          at: now,
        );
      }
    }
  }

  /// The sale adjustment [adjustmentOrderId] was REJECTED by the cloud: remove
  /// its never-uploaded header and minus lines (the held stock, money, cost and
  /// crate rows go through [undoRejectedReversal]). The parent is untouched.
  Future<void> removeRejectedAdjustmentRows(String adjustmentOrderId) async {
    await (delete(orderItems)
          ..where(
            (i) => i.orderId.equals(adjustmentOrderId) & whereBusiness(i),
          ))
        .go();
    await (delete(orders)
          ..where(
            (o) =>
                o.id.equals(adjustmentOrderId) &
                o.kind.equals('adjustment') &
                whereBusiness(o),
          ))
        .go();
  }
}
