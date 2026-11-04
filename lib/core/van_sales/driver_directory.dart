// Who belongs on the Drivers list, and how they are labelled (#146, reworked by
// #748; PRD #139 as amended by #161 / ADR 0019, van-sales spec §9.5 #19).
//
// A pure function over plain inputs. It is a separate file, and not a `where`
// clause inside the list screen, because the rule it encodes is a money rule
// rather than a presentation one: **removing a driver must not be able to hide a
// debt.** A driver who is taken off the pick lists while still owing stays on
// the list, badged, until the balance is settled or deliberately written off.
//
// A driver is a plain `van_drivers` row (a name and an optional phone): no
// sign-in, not a user, not a customer. Each driver's debt is their own — it
// follows them across every trip and every van, and a new driver never inherits
// the last driver's debt.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// One row of the Drivers list.
class DriverListEntry {
  final VanDriverData driver;

  /// Balance across ALL this driver's trips, in kobo. **Negative = they owe.**
  final int balanceKobo;

  const DriverListEntry({required this.driver, required this.balanceKobo});

  String get driverId => driver.id;

  /// True when this driver still owes the business money.
  bool get owes => balanceKobo < 0;

  /// True when the business owes them (they over-paid).
  bool get inCredit => balanceKobo > 0;

  bool get isSettled => balanceKobo == 0;

  /// True when the row is only on the list because of an unsettled balance: the
  /// driver was removed from the pick lists.
  bool get isFormerDriver => driver.isDeleted;
}

/// The "No driver assigned" group of one van: trips loaded with no driver, and
/// what they owe. Listed only while the balance is non-zero.
class NoDriverGroup {
  final String vanStoreId;
  final int balanceKobo;

  const NoDriverGroup({required this.vanStoreId, required this.balanceKobo});

  bool get owes => balanceKobo < 0;
}

/// The Drivers list, in display order.
///
///  1. **Every driver that is not removed is listed**, whatever the balance.
///  2. **A removed driver with a non-zero balance is listed**, badged
///     (`isFormerDriver`). The LEDGER, not the pick list, keeps them visible.
///  3. **A removed driver at zero is not listed.**
///
/// Order: current drivers by name, then former drivers by name.
List<DriverListEntry> buildDriversList({
  required List<VanDriverData> drivers,
  required Map<String, int> balancesKobo,
}) {
  final out = <DriverListEntry>[];
  for (final d in drivers) {
    final balance = balancesKobo[d.id] ?? 0;
    if (d.isDeleted && balance == 0) continue; // rule 3
    out.add(DriverListEntry(driver: d, balanceKobo: balance));
  }
  out.sort((a, b) {
    if (a.isFormerDriver != b.isFormerDriver) {
      return a.isFormerDriver ? 1 : -1;
    }
    return a.driver.name.toLowerCase().compareTo(b.driver.name.toLowerCase());
  });
  return out;
}

/// The "No driver assigned" groups that still carry a balance, largest debt
/// first.
List<NoDriverGroup> buildNoDriverGroups(Map<String, int> noDriverByVan) {
  final out = [
    for (final e in noDriverByVan.entries)
      if (e.value != 0) NoDriverGroup(vanStoreId: e.key, balanceKobo: e.value),
  ];
  out.sort((a, b) => a.balanceKobo.compareTo(b.balanceKobo));
  return out;
}
