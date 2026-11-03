/// **Empties Exchange** (#649, ADR 0033) — the pure rule for empties handed over
/// at Checkout. Crates count per brand:
/// `outstanding = crates in this sale − empties returned at checkout`.
///
/// Every brand at 0 and the order is born `completed`; any brand above 0 and it
/// is born `pending`, with Confirm counting only what is still outstanding.
/// Nothing entered is today's behaviour. A walk-in must return every crate at
/// Checkout (#656; see [walkInExchangeShortfall]). No Flutter, no database.
library;

import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// `crate_ledger.reason` on the pool credit Checkout writes for an exchange.
const String kCheckoutExchangeReason = 'checkout_exchange';

/// `crate_ledger.reason` on the row that undoes [kCheckoutExchangeReason] when
/// the sale is refunded or rejected.
const String kCheckoutExchangeReversalReason = 'checkout_exchange_reversal';

/// `crate_ledger.reason` on the row that undoes a cancelled sale's crates
/// issued to the customer (#709). The movement type stays `adjusted`.
const String kOrderCancelledReason = 'order_cancelled';

/// Why an Empties Exchange was refused.
enum CrateExchangeRefusal { unknownBrand, negative, notQuarterStep, moreThanTaken }

/// An Empties Exchange that must not be recorded. Thrown at the write boundary
/// by `OrdersDao.createOrder`; Checkout turns it into a message first.
class CrateExchangeError implements Exception {
  const CrateExchangeError(this.refusal, this.manufacturerId);

  final CrateExchangeRefusal refusal;
  final String manufacturerId;

  @override
  String toString() => 'CrateExchangeError($refusal, $manufacturerId)';
}

/// The first thing wrong with [returned] against [taken], or null when it can
/// be recorded. Refuses a brand not in the sale, a negative count, a count off
/// the quarter step (#629) and more than the brand's crates in this sale. Old
/// empties go through the customer's Record Crate Return instead.
CrateExchangeError? crateExchangeProblem({
  required Map<String, double> taken,
  required Map<String, double> returned,
}) {
  for (final entry in returned.entries) {
    final brand = entry.key;
    final count = entry.value;
    final crates = taken[brand];
    if (crates == null) {
      return CrateExchangeError(CrateExchangeRefusal.unknownBrand, brand);
    }
    if (count < 0) {
      return CrateExchangeError(CrateExchangeRefusal.negative, brand);
    }
    if (!Qty.isQuarterStep(count)) {
      return CrateExchangeError(CrateExchangeRefusal.notQuarterStep, brand);
    }
    if (count > crates) {
      return CrateExchangeError(CrateExchangeRefusal.moreThanTaken, brand);
    }
  }
  return null;
}

/// The crates still to come back per brand, in [taken]'s order. A fully covered
/// brand is dropped: it gets no `order_crate_lines` row and no `issued` row.
Map<String, double> outstandingCrates(
  Map<String, double> taken,
  Map<String, double> returned,
) => {
  for (final entry in taken.entries)
    if (entry.value - (returned[entry.key] ?? 0) > 0)
      entry.key: entry.value - (returned[entry.key] ?? 0),
};

/// True only when the sale has crates, some empties were entered, and every
/// brand is fully covered. "No balance remaining" means this order, not the
/// customer's overall crate balance.
bool crateExchangeClearsSale({
  required Map<String, double> taken,
  required Map<String, double> returned,
}) =>
    taken.isNotEmpty &&
    returned.values.any((count) => count > 0) &&
    outstandingCrates(taken, returned).isEmpty;

/// #656 — a walk-in has no one to chase for empties, so a walk-in crate sale
/// must return ALL of them at Checkout. The first brand (in [taken]'s order)
/// whose returned count is below the crates in the sale, or null when every
/// brand is covered. A blank or missing count reads as 0 entered. Empty [taken]
/// is null: nothing countable, so nothing to refuse (#649 decision 8).
({String manufacturerId, double taken, double returned})?
walkInExchangeShortfall({
  required Map<String, double> taken,
  required Map<String, double> returned,
}) {
  for (final entry in taken.entries) {
    final back = returned[entry.key] ?? 0;
    if (back < entry.value) {
      return (manufacturerId: entry.key, taken: entry.value, returned: back);
    }
  }
  return null;
}

/// The owner-approved refusal for a [walkInExchangeShortfall] on brand [name].
String walkInShortfallMessage(String name, double taken, double returned) =>
    'A walk-in must return all ${formatQty(taken)} $name '
    '${taken == 1 ? 'empty' : 'empties'} (${formatQty(returned)} entered).';
