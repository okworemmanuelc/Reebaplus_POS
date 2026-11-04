/// **Van-return empties** (#726, ADR 0019 amendment, van-sales spec §11).
///
/// Empties a driver brings back on a van return are credited to the trip's
/// SOURCE warehouse pool as a store-stamped `adjusted` crate_ledger row. No new
/// movement type and no new column: the link to the trip and the driver rides in
/// `crate_ledger.reason`, so the cloud CHECK and the push guard need no change.
library;

/// `crate_ledger.reason` prefix on the pool credit a van return writes. The full
/// reason is `van_return:<tripId>:<driverUserId>`.
const String kVanReturnEmptiesReasonPrefix = 'van_return:';

/// The reason string for a van return's pool credit.
String vanReturnEmptiesReason({
  required String tripId,
  required String driverUserId,
}) => '$kVanReturnEmptiesReasonPrefix$tripId:$driverUserId';

/// True when [reason] marks a van-return pool credit.
bool isVanReturnEmptiesReason(String? reason) =>
    reason != null && reason.startsWith(kVanReturnEmptiesReasonPrefix);

/// The `(tripId, driverUserId)` a van-return reason names, or null when
/// [reason] is not one.
({String tripId, String driverUserId})? parseVanReturnEmptiesReason(
  String? reason,
) {
  if (!isVanReturnEmptiesReason(reason)) return null;
  final parts = reason!
      .substring(kVanReturnEmptiesReasonPrefix.length)
      .split(':');
  if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
  return (tripId: parts[0], driverUserId: parts[1]);
}
