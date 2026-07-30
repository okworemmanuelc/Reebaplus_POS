import 'package:reebaplus_pos/core/database/daos.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';

/// Single source of truth for a period's headline **Total Sales** (#176 /
/// PRD #155 story 28). Item-line gross MINUS discounts, **deposit-exclusive**
/// (a refundable crate deposit is never an `order_items` line, so summing the
/// lines already excludes it). Consumed by the Home dashboard, the Daily
/// Reconciliation, and the Profit report so all three report the SAME figure
/// for a given day — closing the "three screens give three answers" bug the
/// money-flow audit flagged (Home summed `orders.totalAmountKobo`, deposit-IN;
/// Recon/Profit summed item lines, deposit-OUT — they disagreed by construction).
///
/// Only orders that COUNT AS A SALE (recognized at checkout via
/// [orderCountsAsSale] — never a cancelled order) are summed. [inSpan] scopes by
/// the order's `createdAt` day and [inScope] by store — applied to each line's
/// `storeId` AND to the order-level discount, matching the reconciliation's
/// scoping so the three surfaces stay numerically identical. Both predicates
/// default to always-true, so a caller that has already filtered its order set
/// (e.g. the Home dashboard) can pass it through unchanged.
///
/// Equal to the reconciliation's `totalRevenueKobo − discountsKobo` by
/// construction (the reconciliation keeps the gross + discount split for its
/// P&L card; this is the net headline both derive from).
int computeTotalSalesKobo(
  Iterable<OrderWithItems> orders, {
  bool Function(DateTime createdAt) inSpan = _always,
  bool Function(String? storeId) inScope = _anyStore,
}) {
  var total = 0;
  for (final o in orders) {
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    total += orderGoodsNetKobo(o, inScope: inScope);
  }
  return total;
}

/// ONE order's contribution to [computeTotalSalesKobo]: its in-scope item lines
/// at gross, MINUS the order-level discount when the order's own store is in
/// scope. Deposit-exclusive for the same reason the period figure is — a
/// refundable crate deposit is never an `order_items` line.
///
/// Split out (#195) so every PER-ORDER "what did this sale bring in" surface —
/// the Home staff breakdown, the Total Sales drill-down — resolves the figure
/// through the same definition the period headline uses, instead of reaching
/// for `orders.totalAmountKobo` / `net_amount_kobo` (deposit-IN, so a crate
/// shop's staff league table was inflated by every deposit that cashier took).
///
/// The caller decides whether the order counts as a sale and falls in the
/// period; this is purely the money on one order.
int orderGoodsNetKobo(
  OrderWithItems order, {
  bool Function(String? storeId) inScope = _anyStore,
}) {
  var net = 0;
  for (final line in order.items) {
    if (!inScope(line.item.storeId)) continue;
    net += line.item.quantity * line.item.unitPriceKobo;
  }
  return net - orderDiscountKobo(order, inScope: inScope);
}

/// ONE order's discount as it counts toward a scoped figure: `discountKobo`
/// when the ORDER's own store is in scope, else 0.
///
/// The discount is order-level, so unlike the item lines it cannot be scoped
/// per line — the order's store is what decides whether it belongs to this
/// view. Every surface that nets a discount out of a money figure resolves it
/// here (#195), so "which store wears the discount" is answered in one place
/// instead of being re-decided per screen.
int orderDiscountKobo(
  OrderWithItems order, {
  bool Function(String? storeId) inScope = _anyStore,
}) => inScope(order.order.storeId) ? order.order.discountKobo : 0;

bool _always(DateTime _) => true;
bool _anyStore(String? _) => true;

/// The **catalogue-price concession** on ONE sold line (#200 / PRD #155 US 32):
/// how much less than the product's list price the line was actually charged.
///
/// `order_items.catalogue_price_kobo` (#176, migration 0158; cloud parity #183,
/// migration 0160) is written ONLY when the cashier overrode the tier list price
/// — it is NULL when the line went out at list, and NULL for product-less quick
/// sales, so a NULL means "no concession to report", never "unknown". A charge
/// ABOVE list yields a negative figure and is kept signed rather than clamped:
/// an over-charge is as much a margin-review fact as a give-away, and clamping
/// would let one line's markup hide behind another's discount.
///
/// This is DISTINCT from `orders.discount_kobo` (§13.3), which is an explicit,
/// order-level discount already netted out of Total Sales. A concession is the
/// under-the-counter version — the price itself was quietly changed — which is
/// exactly why it needs its own reader.
int lineConcessionKobo({
  required int? cataloguePriceKobo,
  required int unitPriceKobo,
  required int quantity,
}) {
  if (cataloguePriceKobo == null) return 0;
  return (cataloguePriceKobo - unitPriceKobo) * quantity;
}

/// The goods-paid-now vs on-credit split of ONE order's contribution to Total
/// Sales (#176 / PRD #155 story 29). [goodsNet] is the order's Total-Sales share
/// (scoped item lines − scoped discount); [amountPaid] is what was tendered;
/// [depositHeld] is the refundable crate deposit inside that tender (never part
/// of goods). Goods paid now = `clamp(amountPaid − depositHeld, 0, goodsNet)`;
/// the remainder is the credit the drawer won't see today. The two ALWAYS sum to
/// [goodsNet], so summed across a period `paidNow + onCredit == totalSalesKobo`.
/// A zero/negative-net order (discount ≥ goods) folds its (≤0) share into credit
/// to keep that identity exact.
({int paidNow, int onCredit}) splitPaidNowOnCredit({
  required int goodsNet,
  required int amountPaid,
  required int depositHeld,
}) {
  if (goodsNet <= 0) return (paidNow: 0, onCredit: goodsNet);
  final paid = (amountPaid - depositHeld).clamp(0, goodsNet);
  return (paidNow: paid, onCredit: goodsNet - paid);
}
