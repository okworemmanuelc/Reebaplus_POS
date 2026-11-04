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
//   * Returnable per line = the line's quantity minus the minus lines of every
//     adjustment that points at it (the link is `price_snapshot`
//     `adjusts_line_id` on the minus line). A line is a sale line or an edit's
//     PLUS line (#732): goods added by an edit come back like the original goods.
//   * Per product, a return consumes original lines first, then added lines,
//     oldest adjustment first (lib/core/orders/sale_return_allocation.dart).
//   * Prices on returned lines stay at the consumed line's own price and cost.
//   * Discount: the sale's order-level discount is shared out pro rata over the
//     ORIGINAL gross still standing (plus lines never carried any); the return
//     that takes every original unit left takes the rest, so the shares add up
//     to the discount exactly.
//   * Money is proportional to what was actually paid: goods value G is
//     reversed on the customer's account in full (`refund` credit); the part of
//     G that was paid (G x paid-standing / goods-standing) leaves as a `refund`
//     cash-out row (and a `void` of the payment credit leg), or stays as credit
//     when the destination is the balance. The unpaid rest simply cancels debt.
//     The adjustment header records `-paidShare` in `amount_paid_kobo`, which is
//     what makes "paid still standing" derivable for the next return: cash
//     tendered on the sale and on every edit, plus what each edit kept back to
//     pay for its added goods, minus what the headers released.
//   * Crates of crate-tracked bottle lines: see
//     [CratePoolDao.returnCratesForAdjustment]. A returned crate cancels what is
//     owed first; the crates beyond that release the deposit still held, at what
//     was actually paid per crate of that brand (a part deposit at its own rate);
//     only the crates after those hand empties back. So one returned crate never
//     does two of these.

/// What a part return would do, computed once and used both by the pop-up
/// (preview) and by the write.
class PartReturnPlan {
  const PartReturnPlan({
    required this.parent,
    required this.lines,
    required this.goods,
    required this.qtyByLine,
    required this.grossKobo,
    required this.discountShareKobo,
    required this.paidShareKobo,
    required this.depositRefundKobo,
    required this.cratesByBrand,
    required this.depositCratesByBrand,
    required this.emptiesToHandBack,
    required this.coversEverythingLeft,
  });

  final OrderData parent;

  /// The sale's lines, then the plus lines of its adjustments.
  final List<OrderItemData> lines;

  /// One entry per product, in the order a return consumes them.
  final List<ReturnableGoods> goods;

  /// Line consumed (a sale line or an edit's plus line) -> units returned, only
  /// above 0. See [allocateReturn].
  final Map<String, double> qtyByLine;
  final int grossKobo;
  final int discountShareKobo;

  /// Of the goods value, what was actually paid (refundable).
  final int paidShareKobo;
  final int depositRefundKobo;

  /// Brand id -> crates coming back (crate-tracked bottle lines only).
  final Map<String, double> cratesByBrand;

  /// Of [cratesByBrand], the crates that release a deposit: never also handed
  /// back as empties.
  final Map<String, double> depositCratesByBrand;
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

/// `price_snapshot` key on a minus line: the line it returns units of, a sale
/// line or (#732) an edit's plus line.
const String kAdjustsLineKey = 'adjusts_line_id';

/// One adjustment of a sale with its lines (and their products).
typedef SaleAdjustmentLines = ({
  OrderData adjustment,
  List<OrderItemDataWithProductData> lines,
});

/// A sale's goods as they stand: every line with what is left of it.
class _SaleStanding {
  const _SaleStanding({
    required this.lines,
    required this.goods,
    required this.adjustments,
    required this.addedKoboByAdjustment,
  });

  /// The sale's lines, then the plus lines of its adjustments.
  final List<OrderItemData> lines;
  final List<ReturnableGoods> goods;
  final List<OrderData> adjustments;

  /// Adjustment id -> value of the goods it added.
  final Map<String, int> addedKoboByAdjustment;

  Map<String, ReturnableGoods> get goodsByLineId => {
    for (final g in goods)
      for (final l in g.lines) l.lineId: g,
  };
}

/// The line a minus [line] returns units of, or null.
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
  Stream<List<SaleAdjustmentLines>> watchAdjustmentsWithLines(String orderId) {
    return watchAdjustmentsOf(orderId).asyncMap((adjs) async {
      final out = <SaleAdjustmentLines>[];
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

  /// Reads [orderId]'s goods as they stand (#732): the sale's lines and every
  /// adjustment's plus lines, less every minus line.
  Future<_SaleStanding> _saleStanding(String orderId) async {
    final adjustments = await adjustmentsOf(orderId);
    final addedAt = {for (final a in adjustments) a.id: a.createdAt};
    final rows = await (select(orderItems).join([
      leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
    ])..where(
          orderItems.orderId.isIn([orderId, ...addedAt.keys]) &
              whereBusiness(orderItems),
        ))
        .get();
    final lines = <OrderItemDataWithProductData>[];
    final returned = <String, double>{};
    final addedKobo = <String, int>{};
    for (final r in rows) {
      final line = r.readTable(orderItems);
      if (line.orderId != orderId && line.quantity < 0) {
        final target = adjustsLineIdOf(line);
        if (target != null) {
          returned[target] = (returned[target] ?? 0) - line.quantity;
        }
        continue;
      }
      if (line.orderId != orderId) {
        addedKobo[line.orderId] =
            (addedKobo[line.orderId] ?? 0) + line.totalKobo;
      }
      lines.add(OrderItemDataWithProductData(line, r.readTableOrNull(products)));
    }
    return _SaleStanding(
      lines: [for (final l in lines) l.item],
      goods: groupReturnableLines([
        for (final l in lines)
          ReturnableLine(
            lineId: l.item.id,
            productId: l.item.productId,
            storeId: l.item.storeId,
            sold: l.item.quantity,
            returned: returned[l.item.id] ?? 0,
            unitPriceKobo: l.item.unitPriceKobo,
            buyingPriceKobo: l.item.buyingPriceKobo,
            addedAt: addedAt[l.item.orderId],
            name: l.displayName,
            allowParts: l.product?.allowFractionalSales ?? false,
          ),
      ]),
      adjustments: adjustments,
      addedKoboByAdjustment: addedKobo,
    );
  }

  /// [orderId]'s goods per product, in the order a return consumes them: what
  /// the Return and Edit sheets list (#732).
  Future<List<ReturnableGoods>> returnableGoods(String orderId) async =>
      (await _saleStanding(orderId)).goods;

  /// Units still returnable per line of [orderId] (line id -> units, never
  /// below 0), plus lines included: each line's quantity minus every minus line
  /// pointing at it.
  Future<Map<String, double>> returnableQtyByLine(String orderId) async => {
    for (final g in await returnableGoods(orderId))
      for (final l in g.lines) l.lineId: l.standing,
  };

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

  /// Works out a part return of [orderId] without writing anything. A key of
  /// [qtyByLineId] is any line of the product (the sheets send
  /// [ReturnableGoods.lineId]): the units are what comes back of that product,
  /// and [allocateReturn] picks the lines. Throws a [ReturnRefusedException]
  /// when it cannot be done (not a completed sale, a bad or over-the-limit
  /// quantity, nothing picked, deposit kept).
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

    final standing = await _saleStanding(orderId);
    final lines = standing.lines;
    final byId = {for (final l in lines) l.id: l};
    final goodsOf = standing.goodsByLineId;

    final asked = <ReturnableGoods, double>{};
    for (final e in qtyByLineId.entries) {
      if (e.value == 0) continue;
      final goods = goodsOf[e.key];
      if (goods == null || e.value < 0 || !Qty.isQuarterStep(e.value)) {
        throw const ReturnRefusedException(ReturnRefusal.badReturnQty);
      }
      asked[goods] = (asked[goods] ?? 0) + e.value;
    }
    final qty = <String, double>{};
    for (final e in asked.entries) {
      if (e.value > e.key.standing + 1e-9) {
        throw const ReturnRefusedException(ReturnRefusal.overReturn);
      }
      qty.addAll(allocateReturn(e.key, e.value));
    }
    if (qty.isEmpty) {
      throw const ReturnRefusedException(ReturnRefusal.nothingToReturn);
    }

    final adjs = standing.adjustments;
    var remainingGross = 0;
    var returnedGross = 0;
    var originalLeftGross = 0;
    var originalReturnedGross = 0;
    var coversAll = true;
    var coversOriginals = true;
    for (final g in standing.goods) {
      for (final l in g.lines) {
        final left = l.standing;
        final q = qty[l.lineId] ?? 0;
        final takesAll = left <= 0 || (q - left).abs() <= 1e-9;
        remainingGross += lineTotalKobo(l.unitPriceKobo, left);
        returnedGross += lineTotalKobo(l.unitPriceKobo, q);
        if (!takesAll) coversAll = false;
        if (l.isAdded) continue;
        originalLeftGross += lineTotalKobo(l.unitPriceKobo, left);
        originalReturnedGross += lineTotalKobo(l.unitPriceKobo, q);
        if (!takesAll) coversOriginals = false;
      }
    }

    // Discount: it was given on the original goods only, so it is shared over
    // what is left of them; the return that takes the last of them takes the
    // rest. Added goods carry none.
    final usedDiscount = adjs.fold<int>(0, (s, a) => s + (-a.discountKobo));
    final remainingDiscount = math.max(0, parent.discountKobo - usedDiscount);
    final share = coversOriginals
        ? remainingDiscount
        : (originalLeftGross > 0
              ? (remainingDiscount * originalReturnedGross / originalLeftGross)
                    .round()
              : 0);
    final int discountShare = share.clamp(0, remainingDiscount).toInt();
    final goods = returnedGross - discountShare;
    final remainingGoods = remainingGross - remainingDiscount;

    // Paid still standing on the goods: tendered `sale` rows (the sale's and
    // each edit's) minus what earlier adjustments released (their header carries
    // -paidShare). An edit's released money that stayed to pay for its added
    // goods (the smaller of the two) is still standing on those goods.
    final orderIds = [orderId, for (final a in adjs) a.id];
    final salePays = await (select(paymentTransactions)..where(
          (p) =>
              p.orderId.isIn(orderIds) &
              whereBusiness(p) &
              p.voidedAt.isNull() &
              p.type.equals('sale'),
        ))
        .get();
    final tendered = salePays.fold<int>(
      0,
      (s, p) => s + (p.amountKobo > 0 ? p.amountKobo : 0),
    );
    var released = 0;
    for (final a in adjs) {
      final out = -a.amountPaidKobo;
      released +=
          out - math.min(out, standing.addedKoboByAdjustment[a.id] ?? 0);
    }
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
      for (final g in standing.goods)
        for (final l in g.lines) (line: byId[l.lineId]!, qty: l.standing),
    ]);
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
    // A returned crate cancels what is still owed first; only the crates beyond
    // that are the deposit's, so none cancels a debt AND releases a deposit.
    final owed = await db.cratePoolDao.cratesOwedByBrand(orderIds);
    double beyondOwed(String brand, double crates) =>
        math.max(0.0, crates - (owed[brand] ?? 0));
    double sumBeyondOwed(Map<String, double> crates) => crates.entries.fold(
      0,
      (s, e) => s + beyondOwed(e.key, e.value),
    );

    // Those crates release what was actually paid per crate of their brand
    // (#732): a part deposit at its own rate, and a crate that carried no
    // deposit (the sale's own crates, settled at Confirm) releases nothing.
    final paidLines = await (select(db.orderCrateLines)..where(
          (l) =>
              whereBusiness(l) &
              l.orderId.isIn(orderIds) &
              l.depositPaidKobo.isBiggerThanValue(0),
        ))
        .get();
    final paidByBrand = <String, int>{};
    final carriedByBrand = <String, double>{};
    for (final l in paidLines) {
      final brand = l.manufacturerId;
      paidByBrand[brand] = (paidByBrand[brand] ?? 0) + l.depositPaidKobo;
      carriedByBrand[brand] = (carriedByBrand[brand] ?? 0) + l.cratesTaken;
    }
    var heldLeft = held;
    final depositCrates = <String, double>{};
    for (final brand in crateReturned.keys.toList()..sort()) {
      final paid = paidByBrand[brand] ?? 0;
      final carried = carriedByBrand[brand] ?? 0;
      if (heldLeft <= 0 || paid <= 0 || carried <= 0) continue;
      final crates = math.min(
        beyondOwed(brand, crateReturned[brand]!),
        carried,
      );
      final worth = (paid * crates / carried).round();
      final value = math.min(heldLeft, worth);
      if (value <= 0) continue;
      heldLeft -= value;
      depositCrates[brand] = value == worth ? crates : value * carried / paid;
    }
    final returnedCrates = sumBeyondOwed(crateReturned);
    final takesAllDeposit =
        coversAll ||
        (returnedCrates > 0 && returnedCrates >= sumBeyondOwed(crateLeft));
    final deposit = held == 0 || crateReturned.isEmpty
        ? 0
        : (takesAllDeposit ? held : held - heldLeft);

    // Empties to hand back (preview of what returnCratesForAdjustment will do).
    final back = await db.cratePoolDao.emptiesBackFor(
      orderIds: orderIds,
      returnedByBrand: crateReturned,
      depositCratesByBrand: depositCrates,
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
      goods: standing.goods,
      qtyByLine: qty,
      grossKobo: returnedGross,
      discountShareKobo: discountShare,
      paidShareKobo: paid,
      depositRefundKobo: deposit,
      cratesByBrand: crateReturned,
      depositCratesByBrand: depositCrates,
      emptiesToHandBack: names,
      coversEverythingLeft: coversAll,
    );
  }

  /// **Part return** (#712): ONE transaction, behind the #550 guarded reversal,
  /// that writes a sale adjustment for [qtyByLineId] (see [planPartReturn]).
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
  /// the final adjustment that takes everything left, which is how a sale with
  /// an adjustment is returned whole. [damagedQtyByLine] is keyed like
  /// [qtyByLineId].
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
      // Line consumed -> damaged units of it.
      final damagedByLine = <String, double>{};
      for (final e in damagedQtyByLine.entries) {
        final goods = [
          for (final g in plan.goods)
            if (g.lines.any((l) => l.lineId == e.key)) g,
        ];
        final coming = goods.isEmpty
            ? 0.0
            : goods.single.lines.fold<double>(
                0,
                (s, l) => s + (plan.qtyByLine[l.lineId] ?? 0),
              );
        if (e.value < 0 ||
            !Qty.isQuarterStep(e.value) ||
            goods.isEmpty ||
            e.value > coming ||
            (e.value > 0 && goods.single.first.productId == null)) {
          throw const ReturnRefusedException(ReturnRefusal.badDamagedQty);
        }
        damagedUnits += e.value;
        damagedByLine.addAll(
          allocateDamaged(goods.single, plan.qtyByLine, e.value),
        );
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
        final damaged = damagedByLine[line.id] ?? 0;
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
        depositCratesByBrand: plan.depositCratesByBrand,
        staffId: staffId,
      );

      // #551 — damaged units written off at the line's recorded cost.
      for (final e in damagedByLine.entries) {
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
    int? paidOutKobo,
    int? depositOutKobo,
    String? depositMethod,
  }) async {
    final toBalance = destination == RefundDestination.balance;
    final parent = plan.parent;
    // #713 — an edit that also adds goods spends part of the freed paid money
    // on them, so only `paidOutKobo` (<= the paid share) leaves as a refund.
    // #732 — likewise `depositOutKobo` of the deposit released: what stays a
    // credit (the balance destination) never leaves the till.
    final paidOut = paidOutKobo ?? (toBalance ? 0 : plan.paidShareKobo);
    final depositOut =
        depositOutKobo ?? (toBalance ? 0 : plan.depositRefundKobo);
    final goods = plan.goodsKobo;
    final customerId = parent.customerId;
    // #732 — the tender can sit on an edit: a credit sale's added goods paid
    // in cash have no `sale` row on the sale itself.
    final tenderOrderIds = [
      parent.id,
      for (final a in await adjustmentsOf(parent.id)) a.id,
    ];

    // The payment rows come first: they are the cash that leaves the till.
    final salePay = await (select(paymentTransactions)
          ..where(
            (p) =>
                p.orderId.isIn(tenderOrderIds) &
                whereBusiness(p) &
                p.voidedAt.isNull() &
                p.type.equals('sale') &
                p.amountKobo.isBiggerThanValue(0),
          )
          ..orderBy([(p) => OrderingTerm.asc(p.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    if (paidOut > 0 && salePay != null) {
      await db.paymentTransactionsDao.postReversalPayment(
        original: salePay.copyWith(orderId: Value(adjustmentId)),
        reversalType: 'refund',
        method: refundMethod,
        performedBy: staffId,
        amountKobo: paidOut,
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
      if (salePay != null) await leg('debit', paidOut, 'void');

      // The deposit released: what does not leave the till stays as credit.
      if (plan.depositRefundKobo > 0) {
        await leg('debit', plan.depositRefundKobo, 'crate_deposit_refunded');
        await leg(
          'credit',
          plan.depositRefundKobo - depositOut,
          'crate_refund',
        );
      }
    }
    if (depositOut > 0) {
      final depositPay = await (select(paymentTransactions)
            ..where(
              (p) =>
                  p.orderId.isIn(tenderOrderIds) &
                  whereBusiness(p) &
                  p.voidedAt.isNull() &
                  p.type.equals('crate_deposit') &
                  p.amountKobo.isBiggerThanValue(0),
            )
            ..orderBy([(p) => OrderingTerm.asc(p.createdAt)])
            ..limit(1))
          .getSingleOrNull();
      if (depositPay != null) {
        await db.paymentTransactionsDao.postReversalPayment(
          original: depositPay.copyWith(orderId: Value(adjustmentId)),
          reversalType: 'crate_deposit',
          performedBy: staffId,
          amountKobo: -depositOut,
          reason: 'order_part_returned: $reason',
          at: now,
          method: depositMethod,
        );
      }
    }
  }

  /// Claims still queued on this phone that return goods [adjustmentOrderId]
  /// added (#732). Read them BEFORE withdrawing it: without its plus lines
  /// those claims could only fail for ever, so they are withdrawn with it.
  Future<List<SyncQueueData>> queuedClaimsReturningGoodsOf(
    String adjustmentOrderId,
  ) async {
    final plusIds = {
      for (final l in await (select(orderItems)..where(
            (i) =>
                i.orderId.equals(adjustmentOrderId) &
                whereBusiness(i) &
                i.quantity.isBiggerThanValue(0),
          ))
          .get())
        l.id,
    };
    if (plusIds.isEmpty) return const [];
    final claims = await (select(db.syncQueue)..where(
          (q) =>
              q.actionType.equals(kAdjustmentClaimAction) &
              q.businessId.equals(requireBusinessId()),
        ))
        .get();
    return [
      for (final c in claims)
        if (((jsonDecode(c.payload) as Map<String, dynamic>)['p_lines'] as List)
            .any((l) => plusIds.contains((l as Map)['order_item_id'])))
          c,
    ];
  }

  /// The sale adjustment [adjustmentOrderId] was REJECTED by the cloud: remove
  /// its never-uploaded header and minus lines (the held stock, money, cost and
  /// crate rows go through [undoRejectedReversal]). The parent is untouched.
  Future<void> removeRejectedAdjustmentRows(String adjustmentOrderId) async {
    await (delete(db.orderCrateLines)
          ..where((l) => l.orderId.equals(adjustmentOrderId) & whereBusiness(l)))
        .go();
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

// ── Edit a completed sale (#713, ADR 0035 addendum) ─────────────────────────
//
// ONE adjustment record holding the DIFFERENCE between the sale as it stands
// (original minus what was already returned) and the edited cart:
//   * lowered / removed lines  -> MINUS lines, exactly a part return;
//   * raised / added lines     -> PLUS lines at TODAY's price for the customer's
//     tier, written like checkout writes a sale (stock out, FIFO draw-down,
//     crates issued / deposit taken), all referencing the adjustment's id.
// Header totals are the NET (added - returned goods); `amount_paid_kobo` stays
// `-paidShare` released from the sale (what the next return derives paid-standing
// from). Plus lines are returnable through the sale at their own price (#732):
// see the rules at the top of this file.
//
// Money (A = added goods, G = returned goods after discount share, P = paid
// share of G, net = A - G):
//   * net > 0: the customer pays `amountPaid` (<= net) now, the rest is charged
//     to the balance (named customers only); wallet = +G - A + paid.
//   * net < 0: freed paid money first covers A; only R = max(0, P - A) leaves
//     through the refund choice (or stays as credit); the rest of G - A cancels
//     debt on the account.
//   * the paid-for part of the minus side never leaves as cash while the added
//     goods still need it, so the till moves by exactly the net.
//   * a crate deposit D on the added crates (#732) is on top of the goods and is
//     never revenue. Freed money pays it too: see [EditSettlement]. The refund
//     and `crate_deposit` rows stay gross (the refund row is still R, so the
//     Returns figures do not move) and between them the till moves by exactly
//     what the customer hands over or gets back. D rides neither the header
//     totals nor `crate_deposit_paid_kobo`: the header stays added - returned
//     goods; D lives on `order_crate_lines`, the payment and the wallet rows.

/// One product added in the editor (quantity > 0).
class EditAddedLine {
  const EditAddedLine({required this.productId, required this.quantity});
  final String productId;
  final double quantity;
}

/// One crate brand an edit adds: the crates and rate in [line], named for the
/// deposit section.
typedef EditCrateBrand = ({SaleCrateLine line, String name});

/// What an edit would do, for the pop-up (preview) and the write.
class EditSalePlan {
  const EditSalePlan({
    required this.parent,
    required this.minus,
    required this.plusLines,
    required this.crateBrands,
    required this.addedKobo,
    required this.returnedKobo,
    required this.paidOutKobo,
  });
  final OrderData parent;

  /// The part-return half (null when nothing is lowered or removed).
  final PartReturnPlan? minus;

  /// Plus lines in order: product, units, today's unit price (kobo).
  final List<({ProductData product, double qty, int unitPriceKobo})> plusLines;

  /// Crates the plus lines add, per brand (crate-tracked bottles of a business
  /// that tracks crates). Who pays a deposit on them is [SaleTotals]' rule.
  final List<EditCrateBrand> crateBrands;
  final int addedKobo;
  final int returnedKobo;

  /// Cash that would leave as a refund (0 unless net < 0 and money was paid).
  final int paidOutKobo;

  int get netKobo => addedKobo - returnedKobo;
  bool get hasMinus => minus != null;
  bool get hasPlus => plusLines.isNotEmpty;

  /// What this edit settles with [depositKobo] of crate deposit on top.
  EditSettlement settlement([int depositKobo = 0]) => EditSettlement(
    goodsDueKobo: math.max(0, netKobo),
    depositKobo: depositKobo,
    paidBackKobo: paidOutKobo,
    depositBackKobo: minus?.depositRefundKobo ?? 0,
  );
}

/// The result of an edit, for the audit trail, the message and the slip.
class EditSaleOutcome {
  const EditSaleOutcome({
    required this.adjustmentOrderId,
    required this.adjustmentOrderNumber,
    required this.parentOrderNumber,
    required this.storeId,
    required this.addedKobo,
    required this.returnedKobo,
    required this.refundKobo,
    required this.collectedKobo,
    required this.chargedKobo,
    this.depositKobo = 0,
  });
  final String adjustmentOrderId;
  final String adjustmentOrderNumber;
  final String parentOrderNumber;
  final String? storeId;
  final int addedKobo;
  final int returnedKobo;
  final int refundKobo;
  final int collectedKobo;
  final int chargedKobo;

  /// Crate deposit held on the added crates (#732).
  final int depositKobo;
  int get netKobo => addedKobo - returnedKobo;
}

extension EditCompletedSale on OrdersDao {
  /// Works out an edit of [orderId] without writing. [newQtyByLineId] maps any
  /// line of a product ([ReturnableGoods.lineId] from the sheet) -> the quantity
  /// that product should end at, added goods included (products left out stay as
  /// they are); a value above what stands adds the difference at today's price,
  /// a value below it returns the difference like a part return. [addedLines]
  /// are extra products. Throws [ReturnRefusedException] when it cannot be done.
  Future<EditSalePlan> planEditSale(
    String orderId,
    Map<String, double> newQtyByLineId,
    List<EditAddedLine> addedLines,
  ) async {
    final parent = await findById(orderId);
    if (parent == null || parent.kind != 'sale') {
      throw const ReturnRefusedException(ReturnRefusal.notFound);
    }
    final refusal = await returnRefusal(orderId);
    if (refusal != null) throw ReturnRefusedException(refusal);

    final standing = await _saleStanding(orderId);
    final byId = {for (final l in standing.lines) l.id: l};
    final goodsOf = standing.goodsByLineId;

    final lower = <String, double>{};
    final raise = <String, double>{};
    for (final e in newQtyByLineId.entries) {
      final line = byId[e.key];
      if (line == null || e.value < 0 || !Qty.isQuarterStep(e.value)) {
        throw const ReturnRefusedException(ReturnRefusal.badReturnQty);
      }
      final now = goodsOf[e.key]!.standing;
      final diff = e.value - now;
      if (diff.abs() < 1e-9) continue;
      if (diff < 0) {
        lower[e.key] = -diff;
      } else {
        if (line.productId == null) {
          // A quick-sale line has no product to take off the shelf.
          throw const ReturnRefusedException(ReturnRefusal.badEditQty);
        }
        raise[e.key] = diff;
      }
    }
    for (final a in addedLines) {
      if (a.quantity <= 0 || !Qty.isQuarterStep(a.quantity)) {
        throw const ReturnRefusedException(ReturnRefusal.badEditQty);
      }
    }
    if (lower.isEmpty && raise.isEmpty && addedLines.isEmpty) {
      throw const ReturnRefusedException(ReturnRefusal.nothingChanged);
    }

    // Plus lines: raised lines + added products, priced for the customer's tier.
    final wantsPlus = raise.isNotEmpty || addedLines.isNotEmpty;
    if (wantsPlus && parent.vanTripId != null) {
      throw const ReturnRefusedException(ReturnRefusal.notForRoadSale);
    }
    var tier = 'retailer';
    if (parent.customerId != null) {
      final c = await (select(customers)
            ..where((c) => c.id.equals(parent.customerId!) & whereBusiness(c))
            ..limit(1))
          .getSingleOrNull();
      tier = c?.priceTier ?? 'retailer';
    }
    final plus = <({ProductData product, double qty, int unitPriceKobo})>[];
    Future<void> addPlus(String productId, double qty) async {
      final p = await (select(products)
            ..where((x) => x.id.equals(productId) & whereBusiness(x))
            ..limit(1))
          .getSingleOrNull();
      if (p == null) {
        throw const ReturnRefusedException(ReturnRefusal.badEditQty);
      }
      plus.add((
        product: p,
        qty: qty,
        unitPriceKobo: tier == 'wholesaler'
            ? p.wholesalerPriceKobo
            : p.retailerPriceKobo,
      ));
    }

    for (final e in raise.entries) {
      await addPlus(byId[e.key]!.productId!, e.value);
    }
    for (final a in addedLines) {
      await addPlus(a.productId, a.quantity);
    }
    final added = plus.fold<int>(
      0,
      (s, l) => s + lineTotalKobo(l.unitPriceKobo, l.qty),
    );
    final crateBrands = await _addedCrateBrands(plus);

    final PartReturnPlan? minus = lower.isEmpty
        ? null
        : await planPartReturn(orderId, lower);
    final returned = minus?.goodsKobo ?? 0;
    final paid = minus?.paidShareKobo ?? 0;
    return EditSalePlan(
      parent: parent,
      minus: minus,
      plusLines: plus,
      crateBrands: crateBrands,
      addedKobo: added,
      returnedKobo: returned,
      paidOutKobo: math.max(0, paid - added),
    );
  }

  /// The crates [plus] adds, per brand, at each brand's live rate. Empty when
  /// the business does not track crates. The same basis as
  /// `cratesTakenByManufacturer`, which writes them.
  Future<List<EditCrateBrand>> _addedCrateBrands(
    List<({ProductData product, double qty, int unitPriceKobo})> plus,
  ) async {
    final biz = await (select(businesses)
          ..where((b) => b.id.equals(requireBusinessId()))
          ..limit(1))
        .getSingleOrNull();
    final tracksCrates = crateTrackingOn(
      businessType: biz?.type,
      tracksEmptyCrates: biz?.tracksEmptyCrates,
    );
    if (!tracksCrates) return const [];
    final crates = <String, double>{};
    for (final l in plus) {
      final mfr = l.product.manufacturerId;
      if (mfr == null) continue;
      final facts = (unit: l.product.unit, trackEmpties: l.product.trackEmpties);
      if (!isCrateTrackedBottle(facts)) continue;
      crates[mfr] = (crates[mfr] ?? 0) + l.qty;
    }
    final out = <EditCrateBrand>[];
    for (final e in crates.entries) {
      final mfr = await (select(manufacturers)
            ..where((m) => m.id.equals(e.key) & whereBusiness(m))
            ..limit(1))
          .getSingleOrNull();
      out.add((
        line: SaleCrateLine(
          manufacturerId: e.key,
          crates: e.value,
          rateKobo: mfr?.depositAmountKobo ?? 0,
        ),
        name: mfr?.name ?? 'Brand',
      ));
    }
    return out;
  }

  /// **Edit a completed sale** (#713): ONE transaction, ONE adjustment order,
  /// behind the same guarded `pos_claim_sale_adjustment` envelope as a part
  /// return (only the minus half is claimed; an add-only edit sends an empty
  /// claim, which still proves the sale is `completed`). The caller (command)
  /// has checked the Gate; the DAO re-checks nothing about people, only data.
  ///
  /// [amountPaidKobo] is what the customer hands over toward the amount due
  /// ([EditSettlement.dueKobo], default: all of it); what is left of the goods is
  /// charged to a named customer's balance. A walk-in must pay it in full.
  /// [depositPaidByManufacturer] is the crate deposit taken on the ADDED crates,
  /// as at checkout: at most the brand's full deposit, 0 or absent = crates
  /// tracked, and it must be covered by money (never charged to the balance).
  Future<EditSaleOutcome> editCompletedSale({
    required String orderId,
    required Map<String, double> newQtyByLineId,
    List<EditAddedLine> addedLines = const [],
    required String reason,
    required String staffId,
    required String deviceTag,
    RefundDestination refundDestination = RefundDestination.cashOrTransfer,
    String? refundMethod,
    int? amountPaidKobo,
    String paymentMethod = 'cash',
    Map<String, int> depositPaidByManufacturer = const {},
  }) {
    assert(refundMethod == null || refundMethod == 'cash' || refundMethod == 'transfer');
    assert(paymentMethod == 'cash' || paymentMethod == 'transfer');
    return db.transaction(() async {
      final plan = await planEditSale(orderId, newQtyByLineId, addedLines);
      final parent = plan.parent;
      final customerId = parent.customerId;
      final net = plan.netKobo;
      final toBalance = refundDestination == RefundDestination.balance;
      if (toBalance && customerId == null && plan.paidOutKobo > 0) {
        throw const ReturnRefusedException(ReturnRefusal.noCustomerBalance);
      }
      final deposit = _checkedEditDeposit(plan, depositPaidByManufacturer);
      final settle = plan.settlement(deposit);
      final due = settle.goodsDueKobo;
      // What the customer hands over; the goods' share of it, after the deposit
      // and whatever the freed money already covers.
      final handed = (amountPaidKobo ?? settle.dueKobo)
          .clamp(0, settle.dueKobo)
          .toInt();
      if (handed < settle.minPayKobo) {
        throw const ReturnRefusedException(ReturnRefusal.depositNotCovered);
      }
      final tendered = settle.goodsTenderedKobo(handed);
      if (net > 0 && customerId == null && tendered < due) {
        throw const ReturnRefusedException(ReturnRefusal.walkInMustPay);
      }
      // Set-off moves no money, so both of its legs carry one tender.
      final settleMethod = refundMethod ?? paymentMethod;

      final now = DateTime.now();
      final adjustmentId = UuidV7.generate();
      final adjustmentNumber = await generateOrderNumber(deviceTag);
      final guard = await beginGuardedReversal();
      final minus = plan.minus;
      final goodsReturned = plan.returnedKobo;

      final header = OrdersCompanion.insert(
        id: Value(adjustmentId),
        businessId: requireBusinessId(),
        orderNumber: adjustmentNumber,
        customerId: Value(customerId),
        totalAmountKobo: net,
        discountKobo: Value(-(minus?.discountShareKobo ?? 0)),
        netAmountKobo: net,
        amountPaidKobo: Value(-(minus?.paidShareKobo ?? 0)),
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

      final parentLines = {for (final l in minus?.lines ?? <OrderItemData>[]) l.id: l};
      final claimLines = <Map<String, dynamic>>[];
      // #732 — restore layers this edit creates (withdrawn whole if refused)
      // and the units the plus lines draw from EXISTING layers (put back).
      final newLayerIds = <String>{};
      final costDraws = <String, double>{};

      // ── Minus half: exactly a part return's rows ──────────────────────────
      if (minus != null) {
        for (final entry in minus.qtyByLine.entries) {
          final line = parentLines[entry.key]!;
          final q = entry.value;
          final minusId = UuidV7.generate();
          var snapshot = <String, dynamic>{};
          if (line.priceSnapshot != null) {
            try {
              final decoded = jsonDecode(line.priceSnapshot!);
              if (decoded is Map) snapshot = Map<String, dynamic>.from(decoded);
            } catch (_) {}
          }
          snapshot[kAdjustsLineKey] = line.id;
          final row = OrderItemsCompanion.insert(
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
          await into(orderItems).insert(row);
          await db.syncDao.enqueueUpsert('order_items', row);
          claimLines.add({'order_item_id': line.id, 'quantity': q});

          final productId = line.productId;
          if (productId == null) continue;
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
          final layerId = CostBatchesDao.cancelRestoreLayerId(minusId);
          newLayerIds.add(layerId);
          await db.costBatchesDao.recordInflowBatch(
            productId: productId,
            storeId: line.storeId,
            quantity: q,
            costKobo: line.buyingPriceKobo,
            id: layerId,
            allowEmpty: true,
          );
        }
        final adjs = await adjustmentsOf(orderId);
        await db.cratePoolDao.returnCratesForAdjustment(
          orderIds: [orderId, for (final a in adjs) a.id],
          adjustmentOrderId: adjustmentId,
          returnedByBrand: minus.cratesByBrand,
          depositCratesByBrand: minus.depositCratesByBrand,
          staffId: staffId,
        );
      }

      // ── Plus half: written like checkout writes a sale ────────────────────
      if (plan.hasPlus) {
        final storeId = parent.storeId ?? (minus?.lines.first.storeId);
        final saleStore = storeId ?? await _firstStoreOf(parent.id);
        final costLines = [
          for (var i = 0; i < plan.plusLines.length; i++)
            SaleCostLine(
              index: i,
              productId: plan.plusLines[i].product.id,
              storeId: saleStore,
              quantity: plan.plusLines[i].qty,
            ),
        ];
        // Stock guard first: an oversell fails fast, before anything else.
        for (final l in plan.plusLines) {
          final n = await customUpdate(
            'UPDATE inventory SET quantity = quantity - ? '
            'WHERE business_id = ? AND product_id = ? '
            'AND store_id = ? AND quantity >= ?',
            variables: [
              Variable(l.qty),
              Variable(requireBusinessId()),
              Variable(l.product.id),
              Variable(saleStore),
              Variable(l.qty),
            ],
            updates: {inventory},
          );
          if (n == 0) {
            throw InsufficientStockException(productId: l.product.id, requested: l.qty);
          }
        }
        final drawn = <String, double>{};
        final cogs = await db.costBatchesDao.drawDownSale(
          costLines,
          consumedByBatch: drawn,
        );
        drawn.forEach((id, units) {
          if (!newLayerIds.contains(id)) costDraws[id] = units;
        });
        final plusCompanions = <OrderItemsCompanion>[];
        for (var i = 0; i < plan.plusLines.length; i++) {
          final l = plan.plusLines[i];
          final row = OrderItemsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: requireBusinessId(),
            orderId: adjustmentId,
            productId: Value(l.product.id),
            storeId: saleStore,
            quantity: l.qty,
            unitPriceKobo: l.unitPriceKobo,
            buyingPriceKobo: Value(cogs[i] ?? 0),
            totalKobo: lineTotalKobo(l.unitPriceKobo, l.qty),
            cataloguePriceKobo: Value(l.unitPriceKobo),
            createdAt: Value(now),
            lastUpdatedAt: Value(now),
          );
          plusCompanions.add(row);
          await into(orderItems).insert(row);
          await db.syncDao.enqueueUpsert('order_items', row);
          final stock = StockTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: requireBusinessId(),
            productId: l.product.id,
            locationId: saleStore,
            quantityDelta: -l.qty,
            movementType: 'sale',
            orderId: Value(adjustmentId),
            performedBy: Value(staffId),
            lastUpdatedAt: Value(now),
          );
          await into(stockTransactions).insert(stock);
          await db.syncDao.enqueueUpsert('stock_transactions', stock);
          final inv = await (select(inventory)..where(
                (t) =>
                    t.productId.equals(l.product.id) &
                    t.storeId.equals(saleStore) &
                    whereBusiness(t),
              ))
              .getSingle();
          await db.syncDao.enqueueUpsert('inventory', inv);
        }

        // Crates issued / deposit taken, as at checkout (registered customers).
        final biz = await (select(businesses)
              ..where((b) => b.id.equals(requireBusinessId()))
              ..limit(1))
            .getSingleOrNull();
        final tracksCrates = crateTrackingOn(
          businessType: biz?.type,
          tracksEmptyCrates: biz?.tracksEmptyCrates,
        );
        if (tracksCrates && customerId != null) {
          final taken = await cratesTakenByManufacturer(plusCompanions);
          for (final entry in taken.entries) {
            final mfr = await (select(manufacturers)
                  ..where((m) => m.id.equals(entry.key) & whereBusiness(m))
                  ..limit(1))
                .getSingleOrNull();
            final depositPaid = depositPaidByManufacturer[entry.key] ?? 0;
            await db.orderCrateLinesDao.insertLine(
              OrderCrateLinesCompanion.insert(
                businessId: requireBusinessId(),
                orderId: adjustmentId,
                manufacturerId: entry.key,
                cratesTaken: entry.value,
                depositRateKobo: Value(mfr?.depositAmountKobo ?? 0),
                depositPaidKobo: Value(depositPaid),
              ),
            );
            if (depositPaid == 0) {
              await db.cratePoolDao.recordCrateIssueByCustomer(
                customerId: customerId,
                manufacturerId: entry.key,
                quantity: entry.value,
                performedBy: staffId,
                orderId: adjustmentId,
              );
            }
          }
        }

        // Cash taken now (goods + deposit), then the wallet legs.
        await _insertCheckoutPaymentRow(
          orderId: adjustmentId,
          storeId: saleStore,
          amountKobo: tendered,
          method: paymentMethod,
          type: 'sale',
          staffId: staffId,
        );
        await _insertCheckoutPaymentRow(
          orderId: adjustmentId,
          storeId: saleStore,
          amountKobo: deposit,
          method: deposit > 0 ? settleMethod : paymentMethod,
          type: 'crate_deposit',
          staffId: staffId,
        );
        if (customerId != null) {
          // The added goods are a debit; the cash is a credit. The minus half
          // posts its own credit (goods back) and refund legs below, so the
          // wallet nets to +G - A + paid.
          await _postSaleWalletLegs(
            customerId: customerId,
            orderId: adjustmentId,
            staffId: staffId,
            totalAmountKobo: plan.addedKobo + deposit,
            amountPaidKobo: tendered + deposit,
            paymentMethod: paymentMethod,
            crateDepositPaidByManufacturer:
                deposit > 0 ? depositPaidByManufacturer : const {},
          );
        }
      }

      // ── Minus-side money (refund / credit), net of the added goods ────────
      if (minus != null) {
        await _postPartReturnMoney(
          plan: minus,
          adjustmentId: adjustmentId,
          staffId: staffId,
          reason: reason,
          destination: refundDestination,
          refundMethod: deposit > 0 ? settleMethod : refundMethod,
          now: now,
          // Money set off against what this edit takes always moves through
          // the rows; only the rest follows the refund choice.
          paidOutKobo: toBalance ? settle.paidOffsetKobo : plan.paidOutKobo,
          depositOutKobo: toBalance
              ? settle.depositOffsetKobo
              : minus.depositRefundKobo,
          depositMethod: deposit > 0 ? settleMethod : null,
        );
      }

      // Claim: only the minus half needs the over-return guard.
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
          kLocalEnvelopeKey: <String, dynamic>{
            'edit': true,
            'cost_draws': costDraws,
          },
        }),
      );
      await db.syncDao.holdRowsByOrder(held, guard.reversalId);

      final refunded = (!toBalance && minus != null)
          ? plan.paidOutKobo - settle.paidOffsetKobo
          : 0;
      return EditSaleOutcome(
        adjustmentOrderId: adjustmentId,
        adjustmentOrderNumber: adjustmentNumber,
        parentOrderNumber: parent.orderNumber,
        storeId: parent.storeId,
        addedKobo: plan.addedKobo,
        returnedKobo: goodsReturned,
        refundKobo: refunded,
        collectedKobo: handed,
        chargedKobo: due - tendered,
        depositKobo: deposit,
      );
    });
  }

  /// The deposit total of [byBrand], refused unless every amount fits its
  /// brand's added crates, as at checkout: a named customer only, nothing above
  /// the full deposit.
  int _checkedEditDeposit(EditSalePlan plan, Map<String, int> byBrand) {
    var total = 0;
    for (final e in byBrand.entries) {
      if (e.value == 0) continue;
      final full = plan.crateBrands
          .where((b) => b.line.manufacturerId == e.key)
          .fold<int>(0, (s, b) => s + b.line.fullDepositKobo);
      if (e.value < 0 || e.value > full || plan.parent.customerId == null) {
        throw const ReturnRefusedException(ReturnRefusal.badDeposit);
      }
      total += e.value;
    }
    return total;
  }

  Future<String> _firstStoreOf(String orderId) async {
    final l = await (select(orderItems)
          ..where((i) => i.orderId.equals(orderId) & whereBusiness(i))
          ..limit(1))
        .getSingle();
    return l.storeId;
  }
}
