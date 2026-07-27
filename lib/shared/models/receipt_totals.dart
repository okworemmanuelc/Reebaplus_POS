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
