/// The **Crate Shortage** — crates found missing at a count, for every brand
/// whatever its Crate Money Arrangement (PRD #284 decision 7, #293, #296).
///
/// Derived per `(manufacturer, store)` by folding, in time order, the count
/// rows of the Crate Ledger and the `count_shortage` write-offs taken against
/// them. Pure: no database imports. The manufacturer screen, the Crates-tab
/// badge and Daily Reconciliation all read through [foldCrateShortageStatesPerStore],
/// so the three can never disagree.
///
/// The older `manual` (depot-gap) and `customer_forfeit` (#217) write-offs are
/// NOT events here. They stay booked on their own days and never net against
/// this figure.
library;

import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';

/// One event the shortage fold reads.
sealed class CrateShortageEvent {
  const CrateShortageEvent({this.id, this.storeId, required this.createdAt});

  /// The row id. A UUIDv7, so it orders by creation time to the millisecond —
  /// the tie-break for rows from two tables whose `created_at` (stored to the
  /// second) is equal.
  final String? id;

  /// The store the event happened at.
  final String? storeId;

  /// When it happened. The fold runs in this order.
  final DateTime createdAt;
}

/// A count row from the Crate Ledger (`count` or `opening_count`).
class CrateCountMovement extends CrateShortageEvent {
  const CrateCountMovement({
    super.id,
    super.storeId,
    required this.movementType,
    required this.quantityDelta,
    required super.createdAt,
  });

  /// `'count'` or `'opening_count'`.
  final String movementType;

  /// `counted − expected`, as recorded on the movement.
  final int quantityDelta;
}

/// A `count_shortage` row from `crate_shortfall_writeoffs`: positive is a
/// write-off, negative is a reversal.
class CrateShortageWriteOffEvent extends CrateShortageEvent {
  const CrateShortageWriteOffEvent({
    super.id,
    super.storeId,
    required this.crateCount,
    required this.ratePerCrateKobo,
    required super.createdAt,
  });

  /// + crates accepted as lost; − crates a reversal brought back.
  final int crateCount;

  /// The crate value snapshotted on the row.
  final int ratePerCrateKobo;
}

/// Crates written off at one snapshotted rate and not yet reversed.
class CrateWriteOffLayer {
  const CrateWriteOffLayer({
    required this.crates,
    required this.ratePerCrateKobo,
  });

  final int crates;
  final int ratePerCrateKobo;

  @override
  bool operator ==(Object other) =>
      other is CrateWriteOffLayer &&
      other.crates == crates &&
      other.ratePerCrateKobo == ratePerCrateKobo;

  @override
  int get hashCode => Object.hash(crates, ratePerCrateKobo);

  @override
  String toString() => 'CrateWriteOffLayer($crates @ $ratePerCrateKobo)';
}

/// The shortage position of one brand at one store.
class CrateShortageState {
  const CrateShortageState({
    required this.openCrates,
    required this.reversibleCrates,
    required this.outstandingWriteOffs,
  });

  static const CrateShortageState zero = CrateShortageState(
    openCrates: 0,
    reversibleCrates: 0,
    outstandingWriteOffs: [],
  );

  /// Crates found missing that nobody has written off yet — the warning.
  final int openCrates;

  /// Crates a later count found after they had been written off, and so may
  /// be reversed. Never more than [writtenOffCrates].
  final int reversibleCrates;

  /// Written-off crates not yet reversed, oldest first.
  final List<CrateWriteOffLayer> outstandingWriteOffs;

  /// Crates written off and not reversed.
  int get writtenOffCrates =>
      outstandingWriteOffs.fold(0, (sum, l) => sum + l.crates);
}

/// Folds ONE store's events, already in time order.
///
/// - An Opening Count sets the number and raises no shortage.
/// - A count below expected first takes crates found earlier back out of reach
///   of a reversal: they are missing again, and the write-off that was never
///   reversed still covers them. Only the rest of the gap opens shortage.
/// - A count above expected closes open shortage first. The rest raises the
///   warehouse only — it is **not banked** against a later shortage — but
///   crates that had been written off may now be reversed, up to the number
///   written off.
/// - A write-off reduces the open shortage, and only what was still open counts
///   as written off — two tills writing off the same crates offline can't make
///   the shortage negative or the crates reversible twice.
/// - A reversal uses up reversible crates and the newest write-offs first.
CrateShortageState foldCrateShortageStateForStore(
  Iterable<CrateShortageEvent> events,
) {
  var open = 0;
  var reversible = 0;
  final layers = <CrateWriteOffLayer>[];
  int writtenOff() => layers.fold(0, (sum, l) => sum + l.crates);

  for (final e in events) {
    switch (e) {
      case CrateCountMovement(:final movementType, :final quantityDelta):
        if (movementType == kCrateMovementOpeningCount) {
          open = 0;
        } else if (movementType == kCrateMovementCount) {
          if (quantityDelta < 0) {
            final gap = -quantityDelta;
            // Found-but-not-reversed crates are still covered by their
            // write-off, so they go missing again without reopening anything.
            final recovered = gap < reversible ? gap : reversible;
            reversible -= recovered;
            open += gap - recovered;
          } else if (quantityDelta > 0) {
            final closed = quantityDelta < open ? quantityDelta : open;
            open -= closed;
            final excess = quantityDelta - closed;
            final cap = writtenOff();
            reversible = reversible + excess > cap ? cap : reversible + excess;
          }
        }
      case CrateShortageWriteOffEvent(:final crateCount, :final ratePerCrateKobo):
        if (crateCount > 0) {
          // Only what was still open counts as written off: a second till's
          // offline write-off of the same crates can't make them reversible
          // twice.
          final taken = crateCount < open ? crateCount : open;
          open -= taken;
          if (taken > 0) {
            layers.add(
              CrateWriteOffLayer(
                crates: taken,
                ratePerCrateKobo: ratePerCrateKobo,
              ),
            );
          }
        } else if (crateCount < 0) {
          var left = -crateCount;
          reversible = _max0(reversible - left);
          while (left > 0 && layers.isNotEmpty) {
            final top = layers.removeLast();
            if (top.crates > left) {
              layers.add(
                CrateWriteOffLayer(
                  crates: top.crates - left,
                  ratePerCrateKobo: top.ratePerCrateKobo,
                ),
              );
              left = 0;
            } else {
              left -= top.crates;
            }
          }
        }
    }
  }
  return CrateShortageState(
    openCrates: open,
    reversibleCrates: reversible,
    outstandingWriteOffs: List.unmodifiable(layers),
  );
}

/// The open shortage of ONE store's events, already in time order.
int foldCrateShortageForStore(Iterable<CrateShortageEvent> events) =>
    foldCrateShortageStateForStore(events).openCrates;

/// Folds events per store, returning `storeId → state`. Events are sorted by
/// time, then by id; ties beyond that keep their incoming order.
Map<String, CrateShortageState> foldCrateShortageStatesPerStore(
  Iterable<CrateShortageEvent> events,
) {
  final byStore = <String, List<CrateShortageEvent>>{};
  for (final e in events) {
    byStore.putIfAbsent(e.storeId ?? '', () => []).add(e);
  }
  final result = <String, CrateShortageState>{};
  for (final entry in byStore.entries) {
    // List.sort is not stable, so full ties fall back to incoming order.
    final indexed = entry.value.indexed.toList()
      ..sort((a, b) {
        final byTime = a.$2.createdAt.compareTo(b.$2.createdAt);
        if (byTime != 0) return byTime;
        final idA = a.$2.id;
        final idB = b.$2.id;
        if (idA != null && idB != null) {
          final byId = idA.compareTo(idB);
          if (byId != 0) return byId;
        }
        return a.$1.compareTo(b.$1);
      });
    result[entry.key] = foldCrateShortageStateForStore(
      indexed.map((e) => e.$2),
    );
  }
  return result;
}

/// Open shortage per store (`storeId → openCrates`).
Map<String, int> foldCrateShortagePerStore(
  Iterable<CrateShortageEvent> events,
) => {
  for (final e in foldCrateShortageStatesPerStore(events).entries)
    e.key: e.value.openCrates,
};

/// The business total: the sum of each store's open shortage. A surplus at one
/// store never offsets a shortage at another.
int foldTotalCrateShortage(Iterable<CrateShortageEvent> events) =>
    foldCrateShortagePerStore(events).values.fold(0, (a, b) => a + b);

/// The compensating rows for reversing [crates] written-off crates: the newest
/// write-offs first, each at its own snapshotted rate, so a reversal gives back
/// exactly what those write-offs took.
///
/// Empty when [crates] is not positive or exceeds [CrateShortageState.reversibleCrates].
List<CrateWriteOffLayer> planCrateWriteOffReversal(
  CrateShortageState state,
  int crates,
) {
  if (crates <= 0 || crates > state.reversibleCrates) return const [];
  final plan = <CrateWriteOffLayer>[];
  var left = crates;
  for (final layer in state.outstandingWriteOffs.reversed) {
    if (left == 0) break;
    final take = layer.crates < left ? layer.crates : left;
    plan.add(
      CrateWriteOffLayer(crates: take, ratePerCrateKobo: layer.ratePerCrateKobo),
    );
    left -= take;
  }
  return plan;
}

// ── The per-brand read ───────────────────────────────────────────────────────

/// One brand's Crate Shortage in the current store scope.
class CrateShortageBrand {
  const CrateShortageBrand({
    required this.manufacturerId,
    required this.manufacturerName,
    required this.ratePerCrateKobo,
    required this.byStore,
    this.lastWrittenOffAt,
    this.lastWrittenOffBy,
  });

  final String manufacturerId;
  final String manufacturerName;

  /// The brand's crate value today — what the warning is valued at.
  final int ratePerCrateKobo;

  /// `storeId → state` for every store in scope with any count.
  final Map<String, CrateShortageState> byStore;

  /// When the latest write-off in scope was taken, and by whom (a user id).
  final DateTime? lastWrittenOffAt;
  final String? lastWrittenOffBy;

  int get openCrates =>
      byStore.values.fold(0, (sum, s) => sum + s.openCrates);

  int get reversibleCrates =>
      byStore.values.fold(0, (sum, s) => sum + s.reversibleCrates);

  /// [openCrates] at today's crate value. A warning, not a booked loss.
  int get openValueKobo => openCrates * ratePerCrateKobo;

  /// Stores with an open shortage, in no particular order.
  List<String> get storesWithOpenShortage => [
    for (final e in byStore.entries)
      if (e.value.openCrates > 0) e.key,
  ];

  /// Stores with crates that may be reversed.
  List<String> get storesWithReversible => [
    for (final e in byStore.entries)
      if (e.value.reversibleCrates > 0) e.key,
  ];
}

/// Every brand's Crate Shortage in the current store scope.
class CrateShortageRollup {
  const CrateShortageRollup({required this.brands});

  static const CrateShortageRollup empty = CrateShortageRollup(brands: []);

  /// Every brand with any count, in name order.
  final List<CrateShortageBrand> brands;

  /// Brands with an open shortage, biggest money first.
  List<CrateShortageBrand> get openBrands {
    final open = brands.where((b) => b.openCrates > 0).toList()
      ..sort((a, b) {
        final byMoney = b.openValueKobo.compareTo(a.openValueKobo);
        return byMoney != 0
            ? byMoney
            : a.manufacturerName.compareTo(b.manufacturerName);
      });
    return open;
  }

  int get openCrates => brands.fold(0, (sum, b) => sum + b.openCrates);

  int get openValueKobo => brands.fold(0, (sum, b) => sum + b.openValueKobo);

  bool get hasShortage => openCrates > 0;

  CrateShortageBrand? brand(String manufacturerId) {
    for (final b in brands) {
      if (b.manufacturerId == manufacturerId) return b;
    }
    return null;
  }
}

int _max0(int v) => v > 0 ? v : 0;
