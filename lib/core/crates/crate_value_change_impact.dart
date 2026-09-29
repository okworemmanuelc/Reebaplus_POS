/// What a crate value change moves — one **pure function** over plain data
/// (#295, PRD #284 §10, ADR 0024).
///
/// The Settings tab shows this before a crate value is written, so the owner
/// sees the consequence in naira. Statuses that are `count × crate value`
/// re-price; the Customer deposit is money customers actually paid in, and
/// past sales, damages, write-offs and refunds keep the rate they were booked
/// at, so none of those move.
///
/// No database imports: the caller passes the position and the supplier crate
/// debt in crates.
library;

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';

/// One re-priced line of a [CrateValueChangeImpact].
class CrateValueMove {
  final String label;
  final int count;
  final int beforeKobo;
  final int afterKobo;

  const CrateValueMove({
    required this.label,
    required this.count,
    required this.beforeKobo,
    required this.afterKobo,
  });

  int get deltaKobo => afterKobo - beforeKobo;
}

/// The full consequence of moving a brand's crate value from [oldKobo] to
/// [newKobo].
class CrateValueChangeImpact {
  final int oldKobo;
  final int newKobo;

  /// The screen's statuses that re-price, in canonical order. Statuses with no
  /// crates are left out.
  final List<CrateValueMove> statusMoves;

  /// The supplier screen's crate debt for this brand (crates × crate value).
  /// Null when no supplier crate debt exists.
  final CrateValueMove? supplierDebt;

  const CrateValueChangeImpact({
    required this.oldKobo,
    required this.newKobo,
    required this.statusMoves,
    required this.supplierDebt,
  });

  /// Net change across everything that re-prices. Daily Reconciliation's crate
  /// figures are these same crates at the same rate, so they move by this too.
  int get totalDeltaKobo =>
      statusMoves.fold(0, (sum, m) => sum + m.deltaKobo) +
      (supplierDebt?.deltaKobo ?? 0);

  bool get isChange => oldKobo != newKobo;
}

/// Computes what re-prices when [position]'s crate value becomes [newKobo].
///
/// [supplierDebtCrates] is the net crates owed to suppliers for this brand
/// (negative = suppliers owe us). A damaged figure that carries a snapshotted
/// loss (`moneyKobo != count × oldKobo`) is history and does not re-price.
CrateValueChangeImpact computeCrateValueChangeImpact({
  required ManufacturerCratePosition position,
  required int newKobo,
  int supplierDebtCrates = 0,
}) {
  final oldKobo = position.crateValueKobo;
  final newRate = newKobo > 0 ? newKobo : 0;

  final followers = <CrateStatusFigure>[
    position.inWarehouse,
    position.fullCratesInStock,
    position.withCustomersNoDeposit,
    position.short,
    if (position.damaged.moneyKobo == position.damaged.count * oldKobo)
      position.damaged,
  ];

  final moves = <CrateValueMove>[
    for (final s in followers)
      if (s.count != 0)
        CrateValueMove(
          label: s.label,
          count: s.count,
          beforeKobo: s.count * oldKobo,
          afterKobo: s.count * newRate,
        ),
  ];

  return CrateValueChangeImpact(
    oldKobo: oldKobo,
    newKobo: newRate,
    statusMoves: moves,
    supplierDebt: supplierDebtCrates == 0
        ? null
        : CrateValueMove(
            label: 'Crates owed to suppliers',
            count: supplierDebtCrates,
            beforeKobo: supplierDebtCrates * oldKobo,
            afterKobo: supplierDebtCrates * newRate,
          ),
  );
}
