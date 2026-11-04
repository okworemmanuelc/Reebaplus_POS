/// The Sale totals module — the payable math Checkout shows, charges and
/// prints, as one pure, kobo-only rule (#571). No Flutter, no Riverpod.
///
/// Every figure here was previously a getter on `CheckoutPage` reading untyped
/// cart maps. Moving it behind one interface lets the widget keep only state +
/// rendering, and lets the money rules be tested without pumping a page.
/// Behaviour-preserving: each rounding step is carried over verbatim.
library;

import 'dart:math' as math;

import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// Naira (as the cart carries it) to whole kobo, rounding half away from zero.
/// The one place the cart's naira doubles and a cash-received field enter the
/// kobo world.
int koboFromNaira(double naira) => (naira * 100).round();

/// One crate brand in the cart: how many crates and the deposit rate per crate.
class SaleCrateLine {
  const SaleCrateLine({
    required this.manufacturerId,
    required this.crates,
    required this.rateKobo,
  });

  /// Reads the cart's untyped crate-line map
  /// `{manufacturerId, name, crates, rateKobo}`.
  factory SaleCrateLine.fromMap(Map<String, dynamic> line) => SaleCrateLine(
    manufacturerId: (line['manufacturerId'] as String?) ?? '',
    crates: (line['crates'] as num?)?.toDouble() ?? 0,
    rateKobo: (line['rateKobo'] as int?) ?? 0,
  );

  final String manufacturerId;

  /// Fractional crates are allowed (a part-crate of bottles).
  final double crates;

  /// Deposit per crate, kobo.
  final int rateKobo;

  /// The deposit if this brand's crates were deposited in full: proportional,
  /// so half a crate is half the rate, rounded half up to the kobo (#629).
  int get fullDepositKobo => lineTotalKobo(rateKobo, crates);
}

/// The figures of one sale at Checkout. Build with [SaleTotals.compute].
class SaleTotals {
  const SaleTotals._({
    required this.goodsKobo,
    required this.discountKobo,
    required this.depositApplies,
    required this.depositKobo,
    required this.fullDepositKobo,
  });

  /// Computes the totals.
  ///
  /// [goodsTotalNaira] is the cart's goods total — already NET of per-line
  /// discounts (the Cart hands it over as a naira double).
  /// [lineDiscountsKobo] are the per-line discounts (§13.3), summed for
  /// [discountKobo] — information only, they are already inside the goods.
  /// [crateLines] are the cart's crate brands. [depositByManufacturer] is what
  /// the cashier entered per brand (kobo).
  ///
  /// The crate deposit is captured only for a registered customer
  /// ([isWalkIn] false — walk-ins have no wallet to hold it, rule #14) paying
  /// Cash / Transfer ([isCashTransfer] — a Wallet / Credit Sale hands over no
  /// fresh deposit), in a crate business ([isCrateBusiness], §13.4 / rule #13),
  /// with crate brands in the cart.
  factory SaleTotals.compute({
    required double goodsTotalNaira,
    Iterable<int> lineDiscountsKobo = const [],
    List<SaleCrateLine> crateLines = const [],
    required bool isWalkIn,
    required bool isCashTransfer,
    required bool isCrateBusiness,
    Map<String, int> depositByManufacturer = const {},
  }) {
    final applies =
        !isWalkIn && isCashTransfer && isCrateBusiness && crateLines.isNotEmpty;
    return SaleTotals._(
      goodsKobo: koboFromNaira(goodsTotalNaira),
      discountKobo: lineDiscountsKobo.fold<int>(0, (s, d) => s + d),
      depositApplies: applies,
      depositKobo: applies
          ? depositByManufacturer.values.fold<int>(0, (s, v) => s + v)
          : 0,
      fullDepositKobo: crateLines.fold<int>(
        0,
        (s, line) => s + line.fullDepositKobo,
      ),
    );
  }

  /// Goods total, kobo, net of discounts.
  final int goodsKobo;

  /// Per-line discounts summed, kobo (positive; already netted out of goods).
  final int discountKobo;

  /// Whether the crate deposit is captured for this sale.
  final bool depositApplies;

  /// Deposit PAID at checkout, kobo — 0 unless [depositApplies].
  final int depositKobo;

  /// The deposit if every brand's crates were deposited in full — a reference
  /// figure, never added to the payable.
  final int fullDepositKobo;

  /// What the customer settles: goods + the deposit held.
  int get payableKobo => goodsKobo + depositKobo;

  /// Tendered minus payable: positive = change / excess, negative = shortfall.
  int changeKobo(int tenderedKobo) => tenderedKobo - payableKobo;
}

/// What an edit of a completed sale settles (#732, ADR 0035). The edit takes the
/// goods still due plus the crate deposit; it frees the paid money left after the
/// added goods plus any deposit released. One nets against the other, the same
/// rule the edit already applies between its minus and plus sides: the customer
/// hands over [dueKobo] or gets back [handBackKobo], never both, and the till
/// moves by exactly that.
class EditSettlement {
  const EditSettlement({
    required this.goodsDueKobo,
    required this.depositKobo,
    required this.paidBackKobo,
    required this.depositBackKobo,
  });

  /// Net goods the customer owes for the edit (0 when goods went down).
  final int goodsDueKobo;

  /// Crate deposit on the added crates: held, never revenue.
  final int depositKobo;

  /// Paid money freed by the minus side, after the added goods took theirs.
  final int paidBackKobo;

  /// Deposit released by the crates coming back.
  final int depositBackKobo;

  int get _takeKobo => goodsDueKobo + depositKobo;
  int get _backKobo => paidBackKobo + depositBackKobo;

  /// The part of each side set off against the other: no money changes hands.
  int get offsetKobo => math.min(_takeKobo, _backKobo);

  /// Of [offsetKobo], what comes out of [paidBackKobo].
  int get paidOffsetKobo => math.min(paidBackKobo, offsetKobo);

  /// Of [offsetKobo], what comes out of [depositBackKobo].
  int get depositOffsetKobo => offsetKobo - paidOffsetKobo;

  /// What the customer hands over.
  int get dueKobo => _takeKobo - offsetKobo;

  /// What the customer gets back (or keeps as credit).
  int get handBackKobo => _backKobo - offsetKobo;

  /// The least the customer may hand over: a deposit is held money, so unlike
  /// goods it cannot go on the balance (the Checkout rule).
  int get minPayKobo => math.max(0, depositKobo - _backKobo);

  /// Of [handedKobo] (toward [dueKobo]), what pays for goods.
  int goodsTenderedKobo(int handedKobo) =>
      (handedKobo - depositKobo + _backKobo).clamp(0, goodsDueKobo).toInt();

  /// The same edit with [kobo] of crate deposit instead.
  EditSettlement withDeposit(int kobo) => EditSettlement(
    goodsDueKobo: goodsDueKobo,
    depositKobo: kobo,
    paidBackKobo: paidBackKobo,
    depositBackKobo: depositBackKobo,
  );
}
