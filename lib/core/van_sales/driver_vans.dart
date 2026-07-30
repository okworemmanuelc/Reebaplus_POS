// Which vans a driver's profile header names, and how it says it (#208 item 3,
// PRD #139 / ADR 0019, van-sales spec §9.5).
//
// Pure functions over plain inputs, and a separate file from the header widget,
// because the ORDER of the two sources is the whole rule and it has to be
// testable without a widget tree.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// The vans this driver is associated with, most recently driven first.
///
/// **Trips are the primary source and stay that way.** A trip is where the
/// driver actually *went*; an assignment says only where they *may* go, and a
/// removed driver has no assignments left at all (their membership and their
/// `user_stores` rows go with it, while the trips survive — which is exactly
/// why a former driver's profile still shows their history).
///
/// [assignedVanStoreIds] is the fallback, used **only when the trips resolve to
/// nothing** (#208 item 3): a long-dormant driver whose every trip predates the
/// local pull window leaves the header with nothing to name, even though the
/// van they are assigned to is sitting right there in `user_stores`. The
/// fallback is deliberately not merged into the trip-derived list — a manager
/// reading "Van 2 • Van 5" must be reading where the driver has *been*, not a
/// mix of history and paperwork.
///
/// [vanNameById] is `storeId → name` over the business's **vans only** (built
/// from `vansProvider`), so a non-van assignment can never leak into the header
/// — the caller does not have to filter `user_stores` itself.
///
/// Input order is preserved within each source, duplicates and unknown ids
/// dropped.
List<String> resolveDriverVanNames({
  required List<VanTripData> trips,
  required Map<String, String> vanNameById,
  required Iterable<String> assignedVanStoreIds,
}) {
  final fromTrips = _namesOf(
    trips.map((t) => t.vanStoreId),
    vanNameById,
  );
  if (fromTrips.isNotEmpty) return fromTrips;
  return _namesOf(assignedVanStoreIds, vanNameById);
}

List<String> _namesOf(
  Iterable<String> storeIds,
  Map<String, String> vanNameById,
) {
  final seen = <String>[];
  for (final id in storeIds) {
    final name = vanNameById[id];
    if (name == null || name.isEmpty || seen.contains(name)) continue;
    seen.add(name);
  }
  return seen;
}

/// The header line for [vanNames] — two names at most, then a count.
///
/// "No van yet" stays the final fallback: a driver who has never run a trip and
/// holds no van assignment genuinely has no van, and saying so is more useful
/// than an empty line.
String driverVanSummary(List<String> vanNames) {
  if (vanNames.isEmpty) return 'No van yet';
  if (vanNames.length <= 2) return vanNames.join(' • ');
  return '${vanNames.take(2).join(' • ')} +${vanNames.length - 2} more';
}
