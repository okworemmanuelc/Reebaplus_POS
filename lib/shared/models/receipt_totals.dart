/// The money block every receipt prints, derived in ONE place so a reprint can
/// never disagree with the original (#200 / PRD #155 US 33).
///
/// Every receipt prints the same three figures above the total: the goods at
/// their FULL (pre-discount) price, the discount given, then the refundable
/// crate deposit. Before #200 the original print passed the pre-discount gross
/// as Subtotal while a reprint passed the post-discount goods net, and neither
/// renderer printed a discount line at all — so one discounted sale printed two
/// different Subtotals and the discount that explained the gap was invisible on
/// both copies.
class ReceiptTotals {
  const ReceiptTotals({
    required this.subtotalKobo,
    required this.discountKobo,
    required this.depositKobo,
  });

  /// Goods at their full line price, BEFORE any discount.
  final int subtotalKobo;

  /// Discount given on the sale — a positive amount, printed as a minus line.
  final int discountKobo;

  /// Refundable crate deposit collected with the sale. Held money, never revenue
  /// (§13.4), so it keeps its own line above the total.
  final int depositKobo;

  /// What the customer settles: goods − discount + deposit.
  ///
  /// This is the printed block's own arithmetic, so it is what a customer adding
  /// the lines up gets. It equals the recorded `orders.total_amount_kobo` for
  /// every receipt built by [receiptTotalsFromOrder] — by construction, since
  /// that factory derives [subtotalKobo] from it.
  ///
  /// **The checkout path does NOT route its printed total through here** — it
  /// prints the live payable it charged, so the receipt can never disagree with
  /// the till. The two agree by construction: since #202 the cart's goods total
  /// is exactly `sub − discounts`, the same two terms this getter nets. (Until
  /// #202 the cart subtracted a third term that never reached paper,
  /// `customerCrateCredit`, read from the always-empty
  /// `Customer.emptyCratesBalance`; both are now deleted.) If anyone ever
  /// revives customer crate credit, it needs its OWN printed line here;
  /// silently folding it into the total would reintroduce exactly the "total is
  /// lower than the subtotal with nothing explaining it" defect #200 fixed.
  int get totalKobo => subtotalKobo - discountKobo + depositKobo;
}

/// Receipt totals for a RECORDED order — every reprint / reshare path.
///
/// `orders.total_amount_kobo` is already NET of the discount and INCLUSIVE of
/// the crate deposit, so the pre-discount goods figure is reconstructed by
/// taking the deposit out and adding the discount back. [ReceiptTotals.totalKobo]
/// then returns [totalAmountKobo] exactly, which is what makes a reprint tie to
/// the original copy by construction rather than by two call sites agreeing.
ReceiptTotals receiptTotalsFromOrder({
  required int totalAmountKobo,
  required int crateDepositPaidKobo,
  required int discountKobo,
}) => ReceiptTotals(
  subtotalKobo: totalAmountKobo - crateDepositPaidKobo + discountKobo,
  discountKobo: discountKobo,
  depositKobo: crateDepositPaidKobo,
);
